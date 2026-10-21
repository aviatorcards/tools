#!/bin/bash
# vmboot - pick an install ISO (or an existing VM) and boot it with QEMU, and
# manage the VMs it creates. Run `vmboot -h` for usage.
#
# Each VM lives in $VM_ROOT/<name>/ (default ~/VMs):
#   disk.qcow2   the VM's disk (snapshots live inside it)
#   vm.conf      saved settings, as key=value lines
#   efivars.fd   the VM's own UEFI variable store
#   qemu.pid     present while the VM is running

set -euo pipefail

VM_ROOT="${VM_ROOT:-$HOME/VMs}"
SEARCH_DIR="$HOME/Downloads"
DEFAULT_MEM=2G
DEFAULT_CPUS=2
DISK_SIZE=20G
DRY_RUN=0

# Set from flags. Empty means "use the VM's saved value, else the default".
opt_mem="" opt_cpus="" opt_display="" opt_ssh="" opt_firmware=""

usage() {
    cat <<EOF
Usage: vmboot [options]               pick an image or VM from a menu and boot it
       vmboot boot [options] NAME     boot an existing VM
       vmboot list                    list VMs
       vmboot delete NAME             delete a VM and its disk
       vmboot snapshot NAME [TAG]     snapshot a VM's disk (TAG defaults to a timestamp)
       vmboot snapshots NAME          list a VM's snapshots
       vmboot restore NAME TAG        roll a VM's disk back to a snapshot
       vmboot delsnap NAME TAG        delete a snapshot

Boot options:
  -s DIR    where to look for .iso/.img files (default: ~/Downloads)
  -m MEM    guest RAM (default: $DEFAULT_MEM)
  -c N      guest CPUs (default: $DEFAULT_CPUS)
  -z SIZE   size of a newly created disk (default: $DISK_SIZE)
  -p PORT   forward localhost:PORT to the guest's SSH port (-p 0 turns it off)
  -f FW     x86 firmware: uefi or bios (new x86 VMs default to uefi)
  -g        graphical window
  -t        serial console in this terminal (default for arm64 guests)
  -n        dry run: print the QEMU command instead of running it
  -h        show this help

-m, -c, -p, -f, -g and -t are saved with the VM and reused on its next boot.
VMs live in $VM_ROOT/<name>/ (set VM_ROOT to keep them elsewhere).
EOF
}

die() { echo "vmboot: $*" >&2; exit 1; }
bad_usage() { echo "vmboot: $*" >&2; echo "Run 'vmboot -h' for usage." >&2; exit 2; }

# ---- arguments: an optional command, then options and names in any order ----
cmd=""
case ${1:-} in
    boot|list|delete|snapshot|snapshots|restore|delsnap) cmd=$1; shift ;;
esac

positional=()
while [ $# -gt 0 ]; do
    OPTIND=1
    while getopts ":s:m:c:z:p:f:gtnh" opt; do
        case $opt in
            s) SEARCH_DIR=$OPTARG ;;
            m) opt_mem=$OPTARG ;;
            c) opt_cpus=$OPTARG ;;
            z) DISK_SIZE=$OPTARG ;;
            p) opt_ssh=$OPTARG ;;
            f) opt_firmware=$OPTARG ;;
            g) opt_display=window ;;
            t) opt_display=terminal ;;
            n) DRY_RUN=1 ;;
            h) usage; exit 0 ;;
            :) bad_usage "-$OPTARG needs a value" ;;
            *) bad_usage "unknown option -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ $# -gt 0 ]; then positional+=("$1"); shift; fi
done

[[ -z $opt_mem || $opt_mem =~ ^[0-9]+[MmGg]?$ ]] || bad_usage "-m wants a size like 2G or 512M"
[[ -z $opt_cpus || $opt_cpus =~ ^[1-9][0-9]*$ ]] || bad_usage "-c wants a number of CPUs"
[[ -z $opt_ssh || ( $opt_ssh =~ ^[0-9]+$ && $opt_ssh -le 65535 ) ]] || bad_usage "-p wants a port number"
case $opt_firmware in ""|uefi|bios) ;; *) bad_usage "-f wants uefi or bios" ;; esac

# ---- VM helpers ----

# VMs made by older versions of vmboot have only an "arch" file. Those booted
# x86 guests with legacy BIOS, so that's what they keep using.
conf_get() {   # conf_get DIR KEY
    local dir=$1 key=$2 arch
    if [ -f "$dir/vm.conf" ]; then
        sed -n "s/^$key=//p" "$dir/vm.conf" | tail -1
    elif [ -f "$dir/arch" ]; then
        arch=$(cat "$dir/arch")
        case $key in
            arch)     echo "$arch" ;;
            firmware) [ "$arch" = arm64 ] && echo uefi || echo bios ;;
        esac
    fi
}

check_name() {
    case $1 in
        ""|.|..|*/*) die "invalid VM name: '$1'" ;;
    esac
}

# Prints the directory of an existing VM, or dies.
vm_path() {
    check_name "$1"
    [ -f "$VM_ROOT/$1/disk.qcow2" ] || die "no VM named '$1' in $VM_ROOT (try: vmboot list)"
    echo "$VM_ROOT/$1"
}

# Prints the QEMU pid if the VM is running.
vm_pid() {
    local f="$1/qemu.pid" pid
    [ -f "$f" ] || return 1
    pid=$(cat "$f")
    ps -p "$pid" -o comm= 2>/dev/null | grep -q qemu || return 1
    echo "$pid"
}

require_stopped() {
    local pid
    if pid=$(vm_pid "$1"); then
        die "$(basename "$1") is running (pid $pid); shut it down first"
    fi
}

need_qemu_img() { command -v qemu-img >/dev/null || die "qemu-img not found (brew install qemu)"; }

# ---- list / delete / snapshots ----

cmd_list() {
    local d name disk used virt snaps state found=0
    shopt -s nullglob
    for d in "$VM_ROOT"/*/; do
        d=${d%/}
        [ -f "$d/disk.qcow2" ] || continue
        if [ $found -eq 0 ]; then
            printf '%-18s %-6s %-5s %-5s %-4s %-6s %-14s %-5s %s\n' \
                NAME ARCH FW MEM CPUS SSH DISK SNAPS STATE
            found=1
        fi
        name=$(basename "$d")
        disk="$d/disk.qcow2"
        used=$(du -h "$disk" | cut -f1 | tr -d ' ')
        virt=$(qemu-img info -U "$disk" 2>/dev/null | sed -n 's/^virtual size: \([0-9.]*\) \([KMGT]\)iB.*/\1\2/p')
        snaps=$(qemu-img snapshot -l -U "$disk" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
        vm_pid "$d" >/dev/null && state=running || state=stopped
        local ssh_port; ssh_port=$(conf_get "$d" ssh_port)
        printf '%-18s %-6s %-5s %-5s %-4s %-6s %-14s %-5s %s\n' \
            "$name" "$(conf_get "$d" arch)" "$(conf_get "$d" firmware)" \
            "$(conf_get "$d" mem | grep . || echo "$DEFAULT_MEM")" \
            "$(conf_get "$d" cpus | grep . || echo "$DEFAULT_CPUS")" \
            "$([ -n "$ssh_port" ] && [ "$ssh_port" != 0 ] && echo "$ssh_port" || echo -)" \
            "$used of ${virt:-?}" "${snaps:-?}" "$state"
    done
    shopt -u nullglob
    [ $found -eq 1 ] || echo "No VMs in $VM_ROOT"
}

cmd_delete() {
    local dir answer
    dir=$(vm_path "$1")
    require_stopped "$dir"
    echo "This deletes $dir ($(du -sh "$dir" | cut -f1 | tr -d ' ')), including its disk and snapshots."
    read -r -p "Type the VM name to confirm: " answer
    [ "$answer" = "$1" ] || die "names don't match; nothing deleted"
    rm -rf -- "$dir"
    echo "Deleted $1."
}

cmd_snapshot() {
    local dir tag=${2:-$(date +%Y%m%d-%H%M%S)}
    dir=$(vm_path "$1")
    need_qemu_img
    require_stopped "$dir"
    # qemu-img happily makes two snapshots with the same tag, which makes
    # restore and delsnap ambiguous.
    if qemu-img snapshot -l "$dir/disk.qcow2" | awk 'NR > 2 { print $2 }' | grep -qxF -- "$tag"; then
        die "$1 already has a snapshot called '$tag'"
    fi
    qemu-img snapshot -c "$tag" "$dir/disk.qcow2"
    echo "Created snapshot '$tag' of $1."
}

cmd_snapshots() {
    local dir out
    dir=$(vm_path "$1")
    need_qemu_img
    out=$(qemu-img snapshot -l -U "$dir/disk.qcow2")
    [ -n "$out" ] && echo "$out" || echo "$1 has no snapshots."
}

cmd_restore() {
    local dir answer
    dir=$(vm_path "$1")
    need_qemu_img
    require_stopped "$dir"
    read -r -p "Roll $1 back to '$2'? Changes since then are lost. [y/N] " answer
    [[ $answer =~ ^[Yy]$ ]] || die "nothing changed"
    qemu-img snapshot -a "$2" "$dir/disk.qcow2"
    echo "Restored $1 to '$2'."
}

cmd_delsnap() {
    local dir
    dir=$(vm_path "$1")
    need_qemu_img
    require_stopped "$dir"
    qemu-img snapshot -d "$2" "$dir/disk.qcow2"
    echo "Deleted snapshot '$2' of $1."
}

# ---- boot ----

# Guess the guest architecture from an image file. Prints arm64, amd64, i386
# or nothing. Tries, in order: the file name, the ISO volume label, and the
# EFI loader names embedded in the image.
detect_arch() {
    local f=$1 name label
    name=$(basename "$f" | tr '[:upper:]' '[:lower:]')
    case $name in
        *aarch64*|*arm64*|*evbarm*) echo arm64; return ;;
        *amd64*|*x86_64*|*x64*)     echo amd64; return ;;
        *i386*|*i686*)              echo i386;  return ;;
    esac

    # e.g. "ISO 9660 CD-ROM filesystem data 'OpenBSD/arm64   8.0 Install CD'"
    label=$(file -b "$f" | tr '[:upper:]' '[:lower:]')
    case $label in
        *aarch64*|*arm64*|*evbarm*) echo arm64; return ;;
        *amd64*|*x86_64*)           echo amd64; return ;;
        *i386*)                     echo i386;  return ;;
    esac

    # UEFI boot loaders are named per arch: BOOTAA64.EFI, BOOTX64.EFI, BOOTIA32.EFI.
    # They show up in FAT directory entries as "BOOTAA64EFI" (8.3, no dot).
    if LC_ALL=C grep -aqm1 -E 'BOOTAA64 ?\.?EFI' "$f"; then echo arm64; return; fi
    if LC_ALL=C grep -aqm1 -E 'BOOTX64 ?\.?EFI' "$f";  then echo amd64; return; fi
    if LC_ALL=C grep -aqm1 -E 'BOOTIA32 ?\.?EFI' "$f"; then echo i386;  return; fi
}

# Sets image and vm_dir from a menu of images in SEARCH_DIR and existing VMs.
pick_from_menu() {
    local choices=() labels=() f d info size details pid ssh_port choice
    shopt -s nullglob nocaseglob
    for f in "$SEARCH_DIR"/*.iso "$SEARCH_DIR"/*.img; do
        size=$(du -h "$f" | cut -f1 | tr -d ' ')
        info=$(file -b "$f" | sed -n "s/.*'\(.*\)'.*/\1/p" | tr -s ' ')
        choices+=("image:$f")
        labels+=("$(basename "$f")  ($size${info:+, $info})")
    done
    for d in "$VM_ROOT"/*/; do
        d=${d%/}
        [ -f "$d/disk.qcow2" ] || continue
        details="$(conf_get "$d" arch | grep . || echo '?')"
        details+=", $(conf_get "$d" mem | grep . || echo "$DEFAULT_MEM")"
        details+=", $(conf_get "$d" cpus | grep . || echo "$DEFAULT_CPUS") CPUs"
        ssh_port=$(conf_get "$d" ssh_port)
        [ -n "$ssh_port" ] && [ "$ssh_port" != 0 ] && details+=", ssh :$ssh_port"
        pid=$(vm_pid "$d") && details+=", running"
        choices+=("vm:$d")
        labels+=("[VM] $(basename "$d")  ($details)")
    done
    shopt -u nullglob nocaseglob

    [ ${#choices[@]} -gt 0 ] || die "no .iso/.img files in $SEARCH_DIR and no VMs in $VM_ROOT"

    echo "Choose something to boot:"
    PS3="> "
    select _ in "${labels[@]}"; do
        [ -n "${REPLY:-}" ] && [ "$REPLY" -ge 1 ] 2>/dev/null && [ "$REPLY" -le ${#choices[@]} ] && break
        echo "Pick a number from 1 to ${#choices[@]}."
    done
    [ -n "${REPLY:-}" ] || die "nothing chosen"
    choice=${choices[$((REPLY - 1))]}

    case $choice in
        image:*) image=${choice#image:} ;;
        vm:*)    vm_dir=${choice#vm:} ;;
    esac
}

cmd_boot() {
    image="" vm_dir=""
    local arch detected default_name vm_name new_vm=0 saved

    if [ -n "${1:-}" ]; then
        vm_dir=$(vm_path "$1")
    else
        pick_from_menu
    fi

    # A new install: work out the architecture and the VM's name.
    if [ -n "$image" ]; then
        detected=$(detect_arch "$image")
        if [ -z "$detected" ]; then
            echo "Couldn't detect the architecture of $(basename "$image")."
            select detected in arm64 amd64 i386; do [ -n "$detected" ] && break; done
            [ -n "$detected" ] || die "no architecture chosen"
        else
            echo "Detected architecture: $detected"
        fi
        default_name="$(basename "${image%.*}")-$detected"
        read -r -p "VM name [$default_name]: " vm_name
        vm_name=${vm_name:-$default_name}
        check_name "$vm_name"
        vm_dir="$VM_ROOT/$vm_name"
        if [ -f "$vm_dir/disk.qcow2" ]; then
            echo "Using the existing VM '$vm_name', with the installer attached."
            saved=$(conf_get "$vm_dir" arch)
            if [ -n "$saved" ] && [ "$saved" != "$detected" ]; then
                echo "Note: this VM is $saved, but the image looks like $detected. Keeping $saved."
            fi
        else
            new_vm=1
            arch=$detected
        fi
    fi

    local name; name=$(basename "$vm_dir")
    require_stopped "$vm_dir"

    # ---- settings: flags, then the VM's saved values, then defaults ----
    if [ $new_vm -eq 0 ]; then
        arch=$(conf_get "$vm_dir" arch)
        [ -n "$arch" ] || die "$vm_dir has no saved architecture; can't tell which QEMU to use"
    fi
    local mem cpus ssh_port display firmware
    mem=${opt_mem:-$(conf_get "$vm_dir" mem)};   mem=${mem:-$DEFAULT_MEM}
    cpus=${opt_cpus:-$(conf_get "$vm_dir" cpus)}; cpus=${cpus:-$DEFAULT_CPUS}
    ssh_port=${opt_ssh:-$(conf_get "$vm_dir" ssh_port)}
    [ "$ssh_port" = 0 ] && ssh_port=""
    display=${opt_display:-$(conf_get "$vm_dir" display)}
    # arm64 firmware and boot loaders talk to the serial port, so the terminal
    # is the natural default there; x86 installers usually expect a screen.
    if [ -z "$display" ]; then
        [ "$arch" = arm64 ] && display=terminal || display=window
    fi
    firmware=${opt_firmware:-$(conf_get "$vm_dir" firmware)}
    firmware=${firmware:-uefi}
    [ "$arch" = arm64 ] && [ "$firmware" = bios ] && die "arm64 guests always boot with UEFI"

    if [ -n "$ssh_port" ] && lsof -nP -iTCP:"$ssh_port" -sTCP:LISTEN >/dev/null 2>&1; then
        die "port $ssh_port is already in use on this Mac; pick another with -p"
    fi

    # ---- pick the QEMU binary, machine, accelerator and firmware ----
    local host qemu qemu_share fw_code="" fw_vars_template=""
    host=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel Macs
    qemu_share="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)/share/qemu"
    local args=()

    case $arch in
        arm64)
            qemu=qemu-system-aarch64
            args+=(-M virt)
            fw_code="$qemu_share/edk2-aarch64-code.fd"
            fw_vars_template="$qemu_share/edk2-arm-vars.fd"
            if [ "$host" = arm64 ]; then
                args+=(-accel hvf -cpu host)
            else
                args+=(-accel tcg -cpu max)
                echo "Note: arm64 guest on an Intel Mac runs under emulation (slow)."
            fi
            ;;
        amd64|i386)
            if [ "$arch" = amd64 ]; then
                qemu=qemu-system-x86_64
                fw_code="$qemu_share/edk2-x86_64-code.fd"
            else
                qemu=qemu-system-i386
                fw_code="$qemu_share/edk2-i386-code.fd"
            fi
            fw_vars_template="$qemu_share/edk2-i386-vars.fd"
            [ "$firmware" = bios ] && fw_code="" fw_vars_template=""
            args+=(-M q35)
            if [ "$host" = x86_64 ]; then
                args+=(-accel hvf -cpu host)
            else
                args+=(-accel tcg -cpu max)
                echo "Note: x86 guest on Apple Silicon runs under emulation (works, but slow)."
            fi
            ;;
        *) die "unsupported architecture: $arch" ;;
    esac

    command -v "$qemu" >/dev/null || die "$qemu not found (brew install qemu)"
    need_qemu_img

    # UEFI gets read-only firmware code plus a per-VM copy of the variable
    # store, so boot entries the installer writes survive a reboot.
    local disk="$vm_dir/disk.qcow2" vars="$vm_dir/efivars.fd"
    if [ -n "$fw_code" ]; then
        [ -f "$fw_code" ] || die "UEFI firmware not found at $fw_code"
        [ -f "$fw_vars_template" ] || die "UEFI variable store template not found at $fw_vars_template"
        args+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$fw_code")
        args+=(-drive "if=pflash,format=raw,unit=1,file=$vars")
    fi

    args+=(-name "$name" -m "$mem" -smp "$cpus")
    args+=(-drive "file=$disk,if=virtio,format=qcow2")
    args+=(-nic "user,model=virtio-net-pci${ssh_port:+,hostfwd=tcp:127.0.0.1:$ssh_port-:22}")
    args+=(-pidfile "$vm_dir/qemu.pid")

    if [ -n "$image" ]; then
        case $image in
            *.iso|*.ISO) args+=(-drive "file=$image,media=cdrom,readonly=on") ;;
            # .img installers (e.g. OpenBSD's install*.img) are disk images, not CDs
            *) args+=(-drive "file=$image,if=virtio,format=raw,readonly=on") ;;
        esac
    fi

    if [ "$display" = terminal ]; then
        args+=(-nographic)
    else
        args+=(-display cocoa)
        [ "$arch" = arm64 ] && args+=(-device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet)
    fi

    # ---- create or update the VM's files ----
    if [ $new_vm -eq 1 ]; then
        echo "Creating $DISK_SIZE disk at $disk"
    fi
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$vm_dir"
        [ -f "$disk" ] || qemu-img create -q -f qcow2 "$disk" "$DISK_SIZE"
        [ -z "$fw_code" ] || [ -f "$vars" ] || cp "$fw_vars_template" "$vars"
        cat > "$vm_dir/vm.conf" <<EOF
arch=$arch
firmware=$firmware
mem=$mem
cpus=$cpus
display=$display
ssh_port=${ssh_port:-0}
EOF
    fi

    if [ "$display" = terminal ]; then
        echo "Serial console in this terminal. Quit QEMU with Ctrl-A then X."
        [ "$arch" != arm64 ] && echo "Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt."
    fi
    [ -n "$ssh_port" ] && echo "SSH: once the guest runs sshd, connect with: ssh -p $ssh_port <user>@localhost"

    echo
    echo "$qemu ${args[*]}"
    echo
    [ $DRY_RUN -eq 1 ] && exit 0
    exec "$qemu" "${args[@]}"
}

# ---- dispatch ----
name=${positional[0]:-}
nargs=${#positional[@]}
case $cmd in
    "")
        [ "$nargs" -eq 0 ] || bad_usage "unknown command: $name"
        cmd_boot ""
        ;;
    boot)
        [ "$nargs" -eq 1 ] || bad_usage "usage: vmboot boot [options] NAME"
        cmd_boot "$name"
        ;;
    list)
        [ "$nargs" -eq 0 ] || bad_usage "usage: vmboot list"
        cmd_list
        ;;
    delete)
        [ "$nargs" -eq 1 ] || bad_usage "usage: vmboot delete NAME"
        cmd_delete "$name"
        ;;
    snapshot)
        [ "$nargs" -ge 1 ] && [ "$nargs" -le 2 ] || bad_usage "usage: vmboot snapshot NAME [TAG]"
        cmd_snapshot "$name" "${positional[1]:-}"
        ;;
    snapshots)
        [ "$nargs" -eq 1 ] || bad_usage "usage: vmboot snapshots NAME"
        cmd_snapshots "$name"
        ;;
    restore)
        [ "$nargs" -eq 2 ] || bad_usage "usage: vmboot restore NAME TAG"
        cmd_restore "$name" "${positional[1]}"
        ;;
    delsnap)
        [ "$nargs" -eq 2 ] || bad_usage "usage: vmboot delsnap NAME TAG"
        cmd_delsnap "$name" "${positional[1]}"
        ;;
esac
