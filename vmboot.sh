#!/bin/bash
# vmboot - try out OS images in throwaway QEMU VMs, keep the ones you like,
# and clean up after yourself. Run `vmboot -h` for usage.
#
# Each saved VM lives in $VM_ROOT/<name>/ (default ~/VMs):
#   disk.qcow2   the VM's disk (snapshots live inside it)
#   vm.conf      saved settings, as key=value lines
#   efivars.fd   the VM's own UEFI variable store
#   qemu.pid     present while the VM is running
# Throwaway VMs use the same layout under $VM_ROOT/.scratch/ and are deleted
# when QEMU exits unless you choose to keep them. $VM_ROOT/.image-history
# records when each image was last booted, for `vmboot images` and `clean`.

set -euo pipefail

VM_ROOT="${VM_ROOT:-$HOME/VMs}"
SCRATCH_ROOT="$VM_ROOT/.scratch"
HISTORY="$VM_ROOT/.image-history"
SEARCH_DIR="$HOME/Downloads"
DEFAULT_MEM=2G
DEFAULT_CPUS=2
DISK_SIZE=20G
CLEAN_DAYS=30
DRY_RUN=0
KEEP=0
LIVE=0

# Set from flags. Empty means "use the VM's saved value, else the default".
opt_mem="" opt_cpus="" opt_display="" opt_ssh="" opt_firmware=""

usage() {
    cat <<EOF
Usage: vmboot [options]               pick an image or saved VM from a menu and boot it
       vmboot [options] IMAGE         try IMAGE in a throwaway VM
       vmboot boot [options] NAME     boot a saved VM
       vmboot list                    list saved VMs
       vmboot images                  list images in the search folder
       vmboot clean [DAYS]            offer to delete images and VMs unused for DAYS
                                      (default $CLEAN_DAYS)
       vmboot delete NAME             delete a saved VM and its disk
       vmboot snapshot NAME [TAG]     snapshot a VM's disk (TAG defaults to a timestamp)
       vmboot snapshots NAME          list a VM's snapshots
       vmboot restore NAME TAG        roll a VM's disk back to a snapshot
       vmboot delsnap NAME TAG        delete a snapshot

Images boot in a throwaway VM: when QEMU exits you're asked whether to keep
it, and if not, its disk is deleted.

Boot options:
  -s DIR    where to look for .iso/.img files (default: ~/Downloads)
  -k        keep: make a named VM straight away instead of a throwaway one
  -l        live: boot the image with no disk at all (for live ISOs)
  -m MEM    guest RAM (default: $DEFAULT_MEM)
  -c N      guest CPUs (default: $DEFAULT_CPUS)
  -z SIZE   size of a new VM's disk (default: $DISK_SIZE)
  -p PORT   forward localhost:PORT to the guest's SSH port (-p 0 turns it off)
  -f FW     x86 firmware: uefi or bios (new x86 VMs default to uefi)
  -g        graphical window
  -t        serial console in this terminal (default for arm64 guests)
  -n        dry run: print the QEMU command instead of running it
  -h        show this help

-m, -c, -p, -f, -g and -t are saved with a VM and reused on its next boot.
VMs live in $VM_ROOT/<name>/ (set VM_ROOT to keep them elsewhere).
EOF
}

die() { echo "vmboot: $*" >&2; exit 1; }
bad_usage() { echo "vmboot: $*" >&2; echo "Run 'vmboot -h' for usage." >&2; exit 2; }

# ---- arguments: an optional command, then options and names in any order ----
cmd=""
case ${1:-} in
    boot|list|images|clean|delete|snapshot|snapshots|restore|delsnap) cmd=$1; shift ;;
esac

positional=()
while [ $# -gt 0 ]; do
    OPTIND=1
    while getopts ":s:m:c:z:p:f:klgtnh" opt; do
        case $opt in
            s) SEARCH_DIR=$OPTARG ;;
            k) KEEP=1 ;;
            l) LIVE=1 ;;
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
[ $KEEP -eq 1 ] && [ $LIVE -eq 1 ] && bad_usage "-k and -l don't go together"

# ---- small helpers ----

# "today", "1 day ago", "12 days ago" for a Unix time.
fmt_age() {
    local days=$(( ($(date +%s) - $1) / 86400 ))
    case $days in
        0) echo today ;;
        1) echo "1 day ago" ;;
        *) echo "$days days ago" ;;
    esac
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1 | tr -d ' '; }

fmt_kb() {   # fmt_kb KILOBYTES -> e.g. 512M or 3.4G
    if [ "$1" -lt 1048576 ]; then
        echo "$(( ($1 + 512) / 1024 ))M"
    else
        awk -v kb="$1" 'BEGIN { printf "%.1fG\n", kb / 1048576 }'
    fi
}

abs_path() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

ask_yes() {   # ask_yes PROMPT -> succeeds on y/Y
    local answer
    read -r -p "$1 [y/N] " answer || true
    [[ $answer =~ ^[Yy]$ ]]
}

# ---- image history ----

log_image_boot() {
    [ $DRY_RUN -eq 1 ] && return
    mkdir -p "$VM_ROOT"
    printf '%s\t%s\n' "$(date +%s)" "$1" >> "$HISTORY"
}

# Prints the Unix time the image was last booted, or nothing.
image_last_boot() {
    [ -f "$HISTORY" ] || return 0
    awk -F'\t' -v p="$1" '$2 == p { t = $1 } END { if (t) print t }' "$HISTORY"
}

# The most recent of when an image was downloaded and when it was last booted.
image_last_used() {
    local added booted
    added=$(stat -f %B "$1")
    booted=$(image_last_boot "$1")
    [ -n "$booted" ] && [ "$booted" -gt "$added" ] && echo "$booted" || echo "$added"
}

list_images() {   # prints one absolute image path per line
    local f
    shopt -s nullglob nocaseglob
    for f in "$SEARCH_DIR"/*.iso "$SEARCH_DIR"/*.img; do abs_path "$f"; done
    shopt -u nullglob nocaseglob
}

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
        ""|.*|*/*) die "invalid VM name: '$1'" ;;
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

list_vms() {   # prints one saved VM directory per line
    local d
    shopt -s nullglob
    for d in "$VM_ROOT"/*/; do
        [ -f "$d/disk.qcow2" ] && echo "${d%/}"
    done
    shopt -u nullglob
}

need_qemu_img() { command -v qemu-img >/dev/null || die "qemu-img not found (brew install qemu)"; }

# ---- list / images / clean ----

cmd_list() {
    local d name disk virt snaps state ssh_port found=0 w=4 fmt
    # Size the NAME column to the longest name.
    while IFS= read -r d; do
        name=$(basename "$d")
        [ ${#name} -le $w ] || w=${#name}
    done < <(list_vms)
    fmt="%-${w}s  %-6s %-5s %-5s %-4s %-6s %-14s %-5s %-8s %s\n"
    while IFS= read -r d; do
        if [ $found -eq 0 ]; then
            printf "$fmt" NAME ARCH FW MEM CPUS SSH DISK SNAPS STATE "LAST USED"
            found=1
        fi
        name=$(basename "$d")
        disk="$d/disk.qcow2"
        virt=$(qemu-img info -U "$disk" 2>/dev/null | sed -n 's/^virtual size: \([0-9.]*\) \([KMGT]\)iB.*/\1\2/p')
        snaps=$(qemu-img snapshot -l -U "$disk" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
        vm_pid "$d" >/dev/null && state=running || state=stopped
        ssh_port=$(conf_get "$d" ssh_port)
        printf "$fmt" \
            "$name" "$(conf_get "$d" arch)" "$(conf_get "$d" firmware)" \
            "$(conf_get "$d" mem | grep . || echo "$DEFAULT_MEM")" \
            "$(conf_get "$d" cpus | grep . || echo "$DEFAULT_CPUS")" \
            "$([ -n "$ssh_port" ] && [ "$ssh_port" != 0 ] && echo "$ssh_port" || echo -)" \
            "$(human_size "$disk") of ${virt:-?}" "${snaps:-?}" "$state" \
            "$(fmt_age "$(stat -f %m "$disk")")"
    done < <(list_vms)
    [ $found -eq 1 ] || echo "No VMs in $VM_ROOT"
}

cmd_images() {
    local f booted found=0 total=0
    while IFS= read -r f; do
        if [ $found -eq 0 ]; then
            printf '%-44s %-7s %-14s %s\n' IMAGE SIZE DOWNLOADED "LAST BOOTED"
            found=1
        fi
        booted=$(image_last_boot "$f")
        printf '%-44s %-7s %-14s %s\n' "$(basename "$f")" "$(human_size "$f")" \
            "$(fmt_age "$(stat -f %B "$f")")" "$([ -n "$booted" ] && fmt_age "$booted" || echo never)"
        total=$((total + $(du -k "$f" | cut -f1)))
    done < <(list_images)
    if [ $found -eq 0 ]; then
        echo "No .iso/.img files in $SEARCH_DIR"
    else
        echo
        echo "$(fmt_kb "$total") in $SEARCH_DIR"
    fi
}

# Walks through images and VMs nobody has used in DAYS days and offers to
# delete each one. Throwaway VMs left behind by a crash go without asking.
cmd_clean() {
    local days=$1 cutoff d f answer="" booted freed=0 kb n=0
    cutoff=$(( $(date +%s) - days * 86400 ))

    shopt -s nullglob
    for d in "$SCRATCH_ROOT"/*/; do
        d=${d%/}
        vm_pid "$d" >/dev/null && continue
        kb=$(du -sk "$d" | cut -f1)
        rm -rf -- "$d"
        freed=$((freed + kb)); n=$((n + 1))
    done
    shopt -u nullglob
    [ $n -eq 0 ] || echo "Removed $n leftover throwaway VM(s)."

    echo "Looking for images and VMs not used in $days days. Answer y to delete, q to stop."
    n=0
    while IFS= read -r f <&3; do
        [ "$(image_last_used "$f")" -lt "$cutoff" ] || continue
        n=$((n + 1))
        booted=$(image_last_boot "$f")
        read -r -p "  image $(basename "$f") ($(human_size "$f"), downloaded $(fmt_age "$(stat -f %B "$f")"), last booted $([ -n "$booted" ] && fmt_age "$booted" || echo never))? [y/N/q] " answer || answer=q
        case $answer in
            [Yy]) kb=$(du -k "$f" | cut -f1); rm -f -- "$f"; freed=$((freed + kb)) ;;
            [Qq]) break ;;
        esac
    done 3< <(list_images)

    if [[ $answer != [Qq] ]]; then
        while IFS= read -r d <&3; do
            [ "$(stat -f %m "$d/disk.qcow2")" -lt "$cutoff" ] || continue
            vm_pid "$d" >/dev/null && continue
            n=$((n + 1))
            read -r -p "  VM $(basename "$d") ($(human_size "$d"), last used $(fmt_age "$(stat -f %m "$d/disk.qcow2")"))? [y/N/q] " answer || answer=q
            case $answer in
                [Yy]) kb=$(du -sk "$d" | cut -f1); rm -rf -- "$d"; freed=$((freed + kb)) ;;
                [Qq]) break ;;
            esac
        done 3< <(list_vms)
    fi

    [ $n -gt 0 ] || echo "  Nothing that old."
    echo "Freed $(fmt_kb "$freed")."
}

# ---- delete / snapshots ----

cmd_delete() {
    local dir answer
    dir=$(vm_path "$1")
    require_stopped "$dir"
    echo "This deletes $dir ($(human_size "$dir")), including its disk and snapshots."
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
    local dir
    dir=$(vm_path "$1")
    need_qemu_img
    require_stopped "$dir"
    ask_yes "Roll $1 back to '$2'? Changes since then are lost." || die "nothing changed"
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

# Sets image or vm_dir from a menu of images in SEARCH_DIR and saved VMs.
pick_from_menu() {
    local choices=() labels=() f d info details pid ssh_port choice booted
    while IFS= read -r f; do
        info=$(file -b "$f" | sed -n "s/.*'\(.*\)'.*/\1/p" | tr -s ' ')
        booted=$(image_last_boot "$f")
        choices+=("image:$f")
        labels+=("$(basename "$f")  ($(human_size "$f")${info:+, $info}${booted:+, booted $(fmt_age "$booted")})")
    done < <(list_images)
    while IFS= read -r d; do
        details="$(conf_get "$d" arch | grep . || echo '?')"
        details+=", $(conf_get "$d" mem | grep . || echo "$DEFAULT_MEM")"
        details+=", $(conf_get "$d" cpus | grep . || echo "$DEFAULT_CPUS") CPUs"
        ssh_port=$(conf_get "$d" ssh_port)
        [ -n "$ssh_port" ] && [ "$ssh_port" != 0 ] && details+=", ssh :$ssh_port"
        pid=$(vm_pid "$d") && details+=", running"
        choices+=("vm:$d")
        labels+=("[VM] $(basename "$d")  ($details)")
    done < <(list_vms)

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

# Throwaway state, used by the EXIT trap.
scratch="" kept=0
discard_scratch() {
    [ -n "$scratch" ] && [ $kept -eq 0 ] && rm -rf -- "$scratch"
    return 0
}

# After a throwaway VM's QEMU exits: keep it as a saved VM, or let the EXIT
# trap delete it (and maybe the image too).
after_throwaway() {
    local default_name=$1 name used_kb
    if [ $LIVE -eq 0 ]; then
        used_kb=$(du -k "$scratch/disk.qcow2" | cut -f1)
        if [ "$used_kb" -lt 1024 ]; then
            echo "Nothing was written to the disk, so there's nothing to keep."
        elif ask_yes "Keep this VM ($(human_size "$scratch/disk.qcow2"))?"; then
            while true; do
                read -r -p "Name [$default_name]: " name || die "no name given; discarding the VM"
                name=${name:-$default_name}
                case $name in ""|.*|*/*) echo "Names can't start with a dot or contain '/'."; continue ;; esac
                [ -e "$VM_ROOT/$name" ] && { echo "There's already a VM called '$name'."; continue; }
                break
            done
            rm -f "$scratch/qemu.pid"
            mv "$scratch" "$VM_ROOT/$name"
            kept=1
            echo "Kept as '$name'. Boot it again with: vmboot boot $name"
            return
        fi
    fi
    discard_scratch
    echo "Throwaway VM deleted."
    if [ -f "$image" ] && ask_yes "Delete the image $(basename "$image") ($(human_size "$image")) too?"; then
        rm -f -- "$image"
        echo "Deleted $(basename "$image")."
    fi
}

cmd_boot() {   # cmd_boot NAME | cmd_boot "" [IMAGE]
    image="" vm_dir=""
    local arch="" detected default_name="" vm_name new_vm=0 saved mode

    if [ -n "$1" ]; then
        vm_dir=$(vm_path "$1")
    elif [ -n "${2:-}" ]; then
        image=$(abs_path "$2")
    else
        pick_from_menu
    fi

    if [ -z "$image" ]; then
        [ $LIVE -eq 0 ] && [ $KEEP -eq 0 ] || bad_usage "-k and -l are for booting images, not saved VMs"
        mode=vm
    elif [ $KEEP -eq 1 ]; then
        mode=named
    elif [ $LIVE -eq 1 ]; then
        mode=live
    else
        mode=throwaway
    fi

    # Booting an image: work out the architecture.
    if [ -n "$image" ]; then
        detected=$(detect_arch "$image")
        if [ -z "$detected" ]; then
            echo "Couldn't detect the architecture of $(basename "$image")."
            select detected in arm64 amd64 i386; do [ -n "$detected" ] && break; done
            [ -n "$detected" ] || die "no architecture chosen"
        else
            echo "Detected architecture: $detected"
        fi
        # Name new VMs after the image, adding the arch unless it's already in there.
        default_name=$(basename "${image%.*}")
        [ "$(detect_arch "$default_name")" = "$detected" ] || default_name+="-$detected"
        arch=$detected
    fi

    case $mode in
        named)
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
                arch=""
            else
                new_vm=1
            fi
            ;;
        throwaway|live)
            new_vm=1
            if [ $DRY_RUN -eq 1 ]; then
                vm_dir="$SCRATCH_ROOT/DRY-RUN"
            else
                mkdir -p "$SCRATCH_ROOT"
                scratch=$(mktemp -d "$SCRATCH_ROOT/XXXXXX")
                vm_dir=$scratch
                trap discard_scratch EXIT
            fi
            ;;
    esac

    local name; name=$(basename "$vm_dir")
    [ "$mode" = vm ] || [ "$mode" = named ] || name=$default_name
    require_stopped "$vm_dir"

    # ---- settings: flags, then the VM's saved values, then defaults ----
    if [ -z "$arch" ]; then
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
    [ "$mode" = live ] || args+=(-drive "file=$disk,if=virtio,format=qcow2")
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
    case $mode in
        named)     [ $new_vm -eq 1 ] && echo "Creating $DISK_SIZE disk at $disk" ;;
        throwaway) echo "Throwaway VM: you'll be asked whether to keep it when QEMU exits." ;;
        live)      echo "Live boot: no disk attached, nothing is kept." ;;
    esac
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$vm_dir"
        [ "$mode" = live ] || [ -f "$disk" ] || qemu-img create -q -f qcow2 "$disk" "$DISK_SIZE"
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
    [ -z "$image" ] || log_image_boot "$image"

    if [ "$display" = terminal ]; then
        echo "Serial console in this terminal. Quit QEMU with Ctrl-A then X."
        [ "$arch" != arm64 ] && echo "Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt."
    fi
    [ -n "$ssh_port" ] && echo "SSH: once the guest runs sshd, connect with: ssh -p $ssh_port <user>@localhost"

    echo
    echo "$qemu ${args[*]}"
    echo
    [ $DRY_RUN -eq 1 ] && exit 0
    case $mode in
        vm|named) exec "$qemu" "${args[@]}" ;;
    esac

    # Throwaway and live VMs: run QEMU as a child so we can tidy up after it.
    # Ctrl-C still stops QEMU; trapping it here just means we survive to ask
    # what to keep.
    local status=0
    trap ':' INT
    "$qemu" "${args[@]}" || status=$?
    trap - INT
    echo
    [ $status -eq 0 ] || echo "QEMU exited with status $status."
    after_throwaway "$default_name"
}

# ---- dispatch ----
name=${positional[0]:-}
nargs=${#positional[@]}
case $cmd in
    "")
        if [ "$nargs" -eq 0 ]; then
            cmd_boot ""
        elif [ "$nargs" -eq 1 ] && [ -f "$name" ]; then
            cmd_boot "" "$name"
        elif [ "$nargs" -eq 1 ]; then
            bad_usage "no such image or command: $name"
        else
            bad_usage "too many arguments"
        fi
        ;;
    boot)
        [ "$nargs" -eq 1 ] || bad_usage "usage: vmboot boot [options] NAME"
        cmd_boot "$name"
        ;;
    list)
        [ "$nargs" -eq 0 ] || bad_usage "usage: vmboot list"
        cmd_list
        ;;
    images)
        [ "$nargs" -eq 0 ] || bad_usage "usage: vmboot images"
        cmd_images
        ;;
    clean)
        [ "$nargs" -le 1 ] || bad_usage "usage: vmboot clean [DAYS]"
        [[ ${name:-$CLEAN_DAYS} =~ ^[0-9]+$ ]] || bad_usage "DAYS should be a number"
        cmd_clean "${name:-$CLEAN_DAYS}"
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
