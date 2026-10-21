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
# $VM_ROOT/.catalog holds the current release images `vmboot sync` found, and
# $VM_ROOT/mirrors (optional) overrides the built-in list of download mirrors.

set -euo pipefail

VM_ROOT="${VM_ROOT:-$HOME/VMs}"
SCRATCH_ROOT="$VM_ROOT/.scratch"
HISTORY="$VM_ROOT/.image-history"
CATALOG="$VM_ROOT/.catalog"
MIRRORS_FILE="$VM_ROOT/mirrors"
CATALOG_MAX_AGE_DAYS=7
DISTROS="fedora ubuntu alpine openbsd"
SEARCH_DIR="$HOME/Downloads"
DEFAULT_MEM=2G
DEFAULT_CPUS=2
DISK_SIZE=20G
CLEAN_DAYS=30
DRY_RUN=0
KEEP=0
LIVE=0
DOWNLOAD_ONLY=0

# Set from flags. Empty means "use the VM's saved value, else the default".
opt_mem="" opt_cpus="" opt_display="" opt_ssh="" opt_firmware="" opt_arch="" opt_gpu=""

# Set by `get`, which already knows the image's architecture.
known_arch=""

usage() {
    cat <<EOF
Usage: vmboot [options]               pick an image or saved VM from a menu and boot it
       vmboot [options] IMAGE         try IMAGE in a throwaway VM
       vmboot get [options] DISTRO[/VARIANT]
                                      download the current release and try it
       vmboot get                     list what's available to get
       vmboot sync                    refresh the list of current releases
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
  -s DIR    where to look for (and download) .iso/.img files (default: ~/Downloads)
  -a ARCH   with get: arm64 or amd64 (default: this Mac's)
  -d        with get: download only, don't boot
  -k        keep: make a named VM straight away instead of a throwaway one
  -l        live: boot the image with no disk at all (for live ISOs)
  -m MEM    guest RAM (default: $DEFAULT_MEM)
  -c N      guest CPUs (default: $DEFAULT_CPUS)
  -z SIZE   size of a new VM's disk (default: $DISK_SIZE)
  -p PORT   forward localhost:PORT to the guest's SSH port (-p 0 turns it off)
  -f FW     x86 firmware: uefi or bios (new x86 VMs default to uefi)
  -g        graphical window
  -t        serial console in this terminal (default for BSD installers)
  -r        arm64: plain framebuffer (ramfb) instead of virtio-gpu, for OSes
            that only draw to the boot framebuffer (e.g. Redox)
  -n        dry run: print the QEMU command instead of running it
  -h        show this help

-m, -c, -p, -f, -g, -t and -r are saved with a VM and reused on its next boot.
VMs live in $VM_ROOT/<name>/ (set VM_ROOT to keep them elsewhere).

get knows: $DISTROS. Images come from the mirrors in $VM_ROOT/mirrors
(or the built-in ones) and fall back to the official site; checksums always
come from the official release index.
EOF
}

die() { echo "vmboot: $*" >&2; exit 1; }
bad_usage() { echo "vmboot: $*" >&2; echo "Run 'vmboot -h' for usage." >&2; exit 2; }

# ---- arguments: an optional command, then options and names in any order ----
cmd=""
case ${1:-} in
    boot|get|sync|list|images|clean|delete|snapshot|snapshots|restore|delsnap) cmd=$1; shift ;;
esac

positional=()
while [ $# -gt 0 ]; do
    OPTIND=1
    while getopts ":s:a:m:c:z:p:f:dklgtrnh" opt; do
        case $opt in
            s) SEARCH_DIR=$OPTARG ;;
            a) opt_arch=$OPTARG ;;
            d) DOWNLOAD_ONLY=1 ;;
            k) KEEP=1 ;;
            l) LIVE=1 ;;
            m) opt_mem=$OPTARG ;;
            c) opt_cpus=$OPTARG ;;
            z) DISK_SIZE=$OPTARG ;;
            p) opt_ssh=$OPTARG ;;
            f) opt_firmware=$OPTARG ;;
            g) opt_display=window ;;
            t) opt_display=terminal ;;
            r) opt_gpu=ramfb ;;
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
case $opt_arch in
    ""|arm64|amd64) ;;
    aarch64) opt_arch=arm64 ;;
    x86_64)  opt_arch=amd64 ;;
    *) bad_usage "-a wants arm64 or amd64" ;;
esac
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
    local f booted found=0 total=0 w=5 base fmt
    # Size the IMAGE column to the longest name.
    while IFS= read -r f; do
        base=$(basename "$f")
        [ ${#base} -le $w ] || w=${#base}
    done < <(list_images)
    fmt="%-${w}s  %-7s %-14s %s\n"
    while IFS= read -r f; do
        if [ $found -eq 0 ]; then
            printf "$fmt" IMAGE SIZE DOWNLOADED "LAST BOOTED"
            found=1
        fi
        booted=$(image_last_boot "$f")
        printf "$fmt" "$(basename "$f")" "$(human_size "$f")" \
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

# Prints the architecture a file name mentions, if any.
arch_from_name() {
    case $(basename "$1" | tr '[:upper:]' '[:lower:]') in
        *aarch64*|*arm64*|*evbarm*) echo arm64 ;;
        *amd64*|*x86_64*|*x64*)     echo amd64 ;;
        *i386*|*i686*)              echo i386 ;;
        *) return 1 ;;
    esac
}

# Guess the guest architecture from an image file. Prints arm64, amd64 or
# i386; several of them, space-separated, if it's not sure; or nothing.
# Tries, in order: the file name, the ISO volume label, and the EFI loader
# names embedded in the image.
detect_arch() {
    local f=$1 label found=""
    arch_from_name "$f" && return

    # e.g. "ISO 9660 CD-ROM filesystem data 'OpenBSD/arm64   8.0 Install CD'"
    label=$(file -b "$f" | tr '[:upper:]' '[:lower:]')
    case $label in
        *aarch64*|*arm64*|*evbarm*) echo arm64; return ;;
        *amd64*|*x86_64*)           echo amd64; return ;;
        *i386*)                     echo i386;  return ;;
    esac

    # UEFI boot loaders are named per arch: BOOTAA64.EFI, BOOTX64.EFI, BOOTIA32.EFI.
    # They show up in FAT directory entries as "BOOTAA64EFI" (8.3, no dot).
    # Some images carry loaders for several arches, or mention the other
    # names in passing, so only a single hit is conclusive.
    LC_ALL=C grep -aqm1 -E 'BOOTAA64 ?\.?EFI' "$f" && found+=" arm64"
    LC_ALL=C grep -aqm1 -E 'BOOTX64 ?\.?EFI' "$f"  && found+=" amd64"
    LC_ALL=C grep -aqm1 -E 'BOOTIA32 ?\.?EFI' "$f" && found+=" i386"
    echo "${found# }"
}

has_efi_loader() { LC_ALL=C grep -aqm1 -E 'BOOT(AA64|X64|IA32) ?\.?EFI' "$1"; }

# True for an ISO 9660 image (attached as a CD), false for a disk image, even
# one named .iso (Redox's livedisk.iso is a GPT disk).
is_cd_image() {
    if [ -f "$1" ]; then
        [[ $(file -b "$1") == *"ISO 9660"* ]]
    else
        case $1 in *.iso|*.ISO) return 0 ;; *) return 1 ;; esac
    fi
}

# BSD installers expect a serial console; most other things want a screen.
is_bsd_image() {
    local text
    text="$(basename "$1") $([ -f "$1" ] && file -b "$1")"
    [[ $(echo "$text" | tr '[:upper:]' '[:lower:]') =~ openbsd|freebsd|netbsd ]]
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
        detected=${known_arch:-$(detect_arch "$image")}
        if [ -z "$detected" ] || [[ $detected == *" "* ]]; then
            local candidates=${detected:-arm64 amd64 i386}
            if [ -z "$detected" ]; then
                echo "Couldn't detect the architecture of $(basename "$image")."
            else
                echo "$(basename "$image") has boot loaders for more than one architecture. Which is it?"
            fi
            select detected in $candidates; do [ -n "$detected" ] && break; done
            [ -n "$detected" ] || die "no architecture chosen"
        else
            echo "Detected architecture: $detected"
        fi
        # Name new VMs after the image, adding the arch unless it's already in there.
        default_name=$(basename "${image%.*}")
        [ "$(arch_from_name "$default_name")" = "$detected" ] || default_name+="-$detected"
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
    local mem cpus ssh_port display firmware hw gpu
    mem=${opt_mem:-$(conf_get "$vm_dir" mem)};   mem=${mem:-$DEFAULT_MEM}
    cpus=${opt_cpus:-$(conf_get "$vm_dir" cpus)}; cpus=${cpus:-$DEFAULT_CPUS}
    ssh_port=${opt_ssh:-$(conf_get "$vm_dir" ssh_port)}
    [ "$ssh_port" = 0 ] && ssh_port=""
    display=${opt_display:-$(conf_get "$vm_dir" display)}
    if [ -z "$display" ]; then
        if [ -n "$image" ]; then
            is_bsd_image "$image" && display=terminal || display=window
        else
            # VMs from older versions of vmboot: arm64 used the serial console.
            [ "$arch" = arm64 ] && display=terminal || display=window
        fi
    fi
    firmware=${opt_firmware:-$(conf_get "$vm_dir" firmware)}
    if [ -z "$firmware" ]; then
        if [ "$arch" != arm64 ] && [ -f "$image" ] && ! has_efi_loader "$image"; then
            echo "No UEFI boot loader in $(basename "$image"); using legacy BIOS."
            firmware=bios
        else
            firmware=uefi
        fi
    fi
    [ "$arch" = arm64 ] && [ "$firmware" = bios ] && die "arm64 guests always boot with UEFI"
    # New x86 VMs get an AHCI disk and an e1000 network card, which every x86
    # OS has drivers for (ReactOS and ZealOS don't do virtio). arm64 OSes all
    # speak virtio, and so did VMs from older versions of vmboot.
    gpu=${opt_gpu:-$(conf_get "$vm_dir" gpu)}; gpu=${gpu:-virtio}
    hw=$(conf_get "$vm_dir" hw)
    if [ -z "$hw" ]; then
        [ $new_vm -eq 1 ] && [ "$arch" != arm64 ] && hw=standard || hw=virtio
    fi

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

    local disk_if=virtio nic=virtio-net-pci
    [ "$hw" = standard ] && disk_if=ide nic=e1000   # on q35, "ide" is AHCI

    args+=(-name "$name" -m "$mem" -smp "$cpus")
    [ "$mode" = live ] || args+=(-drive "file=$disk,if=$disk_if,format=qcow2")
    args+=(-nic "user,model=$nic${ssh_port:+,hostfwd=tcp:127.0.0.1:$ssh_port-:22}")
    args+=(-pidfile "$vm_dir/qemu.pid")

    if [ -n "$image" ]; then
        if ! is_cd_image "$image"; then
            # Disk images (OpenBSD's install*.img, Redox's livedisk.iso). The
            # guest's writes go to a temporary overlay, never the image.
            args+=(-drive "file=$image,if=$disk_if,format=raw,snapshot=on")
        elif [ "$arch" = arm64 ]; then
            # The virt machine has no IDE, so the CD goes on virtio-scsi.
            args+=(-device virtio-scsi-pci -drive "if=none,id=cd,media=cdrom,readonly=on,file=$image" -device scsi-cd,drive=cd)
        else
            args+=(-drive "file=$image,media=cdrom,readonly=on")
        fi
    fi

    if [ "$display" = terminal ]; then
        args+=(-nographic)
    else
        args+=(-display cocoa)
        if [ "$arch" = arm64 ]; then
            [ "$gpu" = ramfb ] && args+=(-device ramfb) || args+=(-device virtio-gpu-pci)
            args+=(-device qemu-xhci -device usb-kbd -device usb-tablet)
        fi
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
hw=$hw
gpu=$gpu
EOF
    fi
    [ -z "$image" ] || log_image_boot "$image"

    if [ "$display" = terminal ]; then
        echo "Serial console in this terminal. Quit QEMU with Ctrl-A then X."
        [ "$arch" != arm64 ] && echo "Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt."
    elif [ "$arch" = arm64 ] && [ "$gpu" = virtio ]; then
        echo "Tip: if the window stays blank once the OS is up, try again with -r, or -t for the serial console."
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

# ---- sync / get ----

# Catalog lines are tab-separated:
#   distro  variant  version  arch  url  sha256  display
# display is "window" for desktop images (so arm64 ones don't default to the
# serial console) and empty otherwise. Each sync_<distro> prints its lines,
# default variant first.

sync_fedora() {
    local json ver
    json=$(curl -fsSL https://getfedora.org/releases.json) || return 1
    ver=$(jq -r '[.[].version | select(test("^[0-9]+$")) | tonumber] | max' <<<"$json")
    jq -r --arg v "$ver" '
        [ .[] | select(.version == $v and (.arch == "aarch64" or .arch == "x86_64"))
              | (if   (.link | test("Workstation-Live")) then [0, "workstation", "window"]
                 elif (.link | test("KDE-Desktop-Live")) then [1, "kde", "window"]
                 elif (.link | test("Server-dvd"))       then [2, "server", ""]
                 elif (.link | test("Everything-netinst")) then [3, "netinst", ""]
                 else empty end) as $m
              | [$m[0], "fedora", $m[1], .version,
                 (if .arch == "aarch64" then "arm64" else "amd64" end), .link, .sha256, $m[2]] ]
        | sort_by(.[0]) | .[] | .[1:] | @tsv' <<<"$json"
}

sync_alpine() {
    local a arch yaml
    for a in aarch64 x86_64; do
        [ $a = aarch64 ] && arch=arm64 || arch=amd64
        yaml=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$a/latest-releases.yaml") || return 1
        # Each "-" starts a release; its fields are "  key: value" lines.
        awk -v arch=$arch -v a=$a '
            function flush() {
                if (r["file"] ~ /\.iso$/ && r["flavor"] ~ /^alpine-(standard|virt|extended)$/) {
                    v = r["flavor"]; sub(/^alpine-/, "", v)
                    printf "alpine\t%s\t%s\t%s\thttps://dl-cdn.alpinelinux.org/alpine/%s/releases/%s/%s\t%s\t\n",
                        v, r["version"], arch, r["branch"], a, r["file"], r["sha256"]
                }
                split("", r)
            }
            /^-/ { flush() }
            /^  [a-z0-9]+: / { k = $1; sub(/:$/, "", k); v = $0; sub(/^  [a-z0-9]+: /, "", v); r[k] = v }
            END { flush() }' <<<"$yaml" |
            # standard first, as the default
            awk -F'\t' '$2 == "standard" { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }'
    done
}

sync_ubuntu() {
    local ver dir arch base sums type line file
    # The newest LTS that's still supported.
    ver=$(curl -fsSL https://changelogs.ubuntu.com/meta-release-lts |
        awk '/^Version:/ { v = $2 } /^Supported: 1/ { s = v } END { print s }') || return 1
    [ -n "$ver" ] || return 1
    dir=$(echo "$ver" | cut -d. -f1,2)
    for arch in amd64 arm64; do
        # amd64 images live on releases.ubuntu.com, arm64 ones on cdimage.
        if [ $arch = amd64 ]; then
            base="https://releases.ubuntu.com/$dir"
        else
            base="https://cdimage.ubuntu.com/releases/$dir/release"
        fi
        sums=$(curl -fsSL "$base/SHA256SUMS") || return 1
        for type in desktop live-server; do
            line=$(grep -E " \*ubuntu-[0-9.]+-$type-$arch\.iso$" <<<"$sums" | sort -t'*' -k2 -V | tail -1)
            [ -n "$line" ] || continue
            file=${line#*\*}
            printf 'ubuntu\t%s\t%s\t%s\t%s/%s\t%s\t%s\n' \
                "$([ $type = desktop ] && echo desktop || echo server)" \
                "$(echo "$file" | sed 's/^ubuntu-\([0-9.]*\)-.*/\1/')" \
                $arch "$base" "$file" "${line%% *}" \
                "$([ $type = desktop ] && echo window)"
        done
    done
}

sync_openbsd() {
    local versions v arch sums file sum
    versions=$(curl -fsSL https://cdn.openbsd.org/pub/OpenBSD/ |
        grep -o 'href="[0-9]*\.[0-9]*/"' | grep -o '[0-9]*\.[0-9]*' |
        sort -t. -k1,1nr -k2,2nr | head -3) || return 1
    for arch in arm64 amd64; do
        # arm64 boots the .img as a disk; amd64 boots the CD image.
        for v in $versions; do
            [ $arch = arm64 ] && file="install${v/./}.img" || file="install${v/./}.iso"
            sums=$(curl -fsSL "https://cdn.openbsd.org/pub/OpenBSD/$v/$arch/SHA256" 2>/dev/null) || continue
            sum=$(sed -n "s/^SHA256 ($file) = //p" <<<"$sums" | head -1)
            [ -n "$sum" ] || continue
            printf 'openbsd\tinstall\t%s\t%s\thttps://cdn.openbsd.org/pub/OpenBSD/%s/%s/%s\t%s\t\n' \
                "$v" $arch "$v" $arch "$file" "$sum"
            break
        done
    done
}

cmd_sync() {
    local d out tmp
    command -v jq >/dev/null || die "jq not found (brew install jq)"
    mkdir -p "$VM_ROOT"
    tmp=$(mktemp "$VM_ROOT/.catalog.XXXXXX")
    echo "Checking current releases:"
    for d in $DISTROS; do
        printf '  %-8s ' "$d"
        if out=$(sync_$d 2>/dev/null) && [ -n "$out" ]; then
            echo "$out" >> "$tmp"
            echo "$(cut -f3 <<<"$out" | sort -u | tr '\n' ' ')"
        else
            echo "couldn't check; keeping what the catalog had"
            [ -f "$CATALOG" ] && awk -F'\t' -v d="$d" '$1 == d' "$CATALOG" >> "$tmp"
        fi
    done
    mv "$tmp" "$CATALOG"
}

# Syncs first if the catalog is missing or stale.
ensure_catalog() {
    if [ ! -f "$CATALOG" ]; then
        cmd_sync
    elif [ "$(stat -f %m "$CATALOG")" -lt $(( $(date +%s) - CATALOG_MAX_AGE_DAYS * 86400 )) ]; then
        echo "The release list is over $CATALOG_MAX_AGE_DAYS days old; refreshing it."
        cmd_sync || echo "Couldn't refresh it; using the old one."
    fi
    echo
}

host_arch() { [ "$(uname -m)" = arm64 ] && echo arm64 || echo amd64; }

# Each line: an official URL prefix and the same tree on a mirror. Mirrors are
# tried in this order, then the official URL itself.
mirror_rules() {
    if [ -f "$MIRRORS_FILE" ]; then
        grep -v '^[[:space:]]*\(#\|$\)' "$MIRRORS_FILE"
        return
    fi
    cat <<'EOF'
https://download.fedoraproject.org/pub/fedora/  https://mirrors.rit.edu/fedora/fedora/
https://download.fedoraproject.org/pub/fedora/  https://plug-mirror.rcac.purdue.edu/fedora/fedora/
https://dl-cdn.alpinelinux.org/alpine/          https://plug-mirror.rcac.purdue.edu/alpine/
https://releases.ubuntu.com/                    https://mirrors.rit.edu/ubuntu-releases/
https://releases.ubuntu.com/                    https://plug-mirror.rcac.purdue.edu/ubuntu-releases/
https://cdimage.ubuntu.com/                     https://mirrors.rit.edu/ubuntu-cdimage/
https://cdn.openbsd.org/pub/OpenBSD/            https://mirrors.rit.edu/OpenBSD/
https://cdn.openbsd.org/pub/OpenBSD/            https://plug-mirror.rcac.purdue.edu/openbsd/
EOF
}

# Prints the URLs to try for a download, best first.
sources_for() {
    local url=$1 official mirror
    while read -r official mirror; do
        case $url in "$official"*) echo "$mirror${url#"$official"}" ;; esac
    done < <(mirror_rules)
    echo "$url"
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Downloads URL into SEARCH_DIR as FILE, trying mirrors first, and checks it
# against SUM. Sets image_path. Interrupted downloads resume from FILE.part.
download_image() {
    local url=$1 sum=$2 file=$3 dest part src host
    dest="$SEARCH_DIR/$file"
    part="$dest.part"
    image_path=$dest
    if [ -f "$dest" ]; then
        if [ "$(sha256_of "$dest")" = "$sum" ]; then
            echo "Already downloaded: $dest"
            return
        fi
        die "$dest is there but doesn't match the release checksum; move it aside first"
    fi
    if [ $DRY_RUN -eq 1 ]; then
        echo "Would download $file, trying in order:"
        sources_for "$url" | sed 's/^/  /'
        return
    fi
    mkdir -p "$SEARCH_DIR"
    local finished
    while IFS= read -r src; do
        host=$(echo "$src" | sed 's|^[a-z]*://\([^/]*\)/.*|\1|')
        echo "Downloading $file from $host"
        finished=1
        curl -fL --progress-bar --retry 2 --connect-timeout 15 -C - -o "$part" "$src" || {
            finished=0
            echo "  couldn't get it from $host"
        }
        [ -f "$part" ] || continue
        if [ "$(sha256_of "$part")" = "$sum" ]; then
            mv "$part" "$dest"
            echo "Checksum OK: $dest"
            return
        fi
        # An unfinished download can carry on from the next source; a
        # finished one with the wrong checksum is bad.
        if [ $finished -eq 1 ]; then
            echo "  the file from $host doesn't match the checksum; discarding it"
            rm -f "$part"
        fi
    done < <(sources_for "$url")
    die "couldn't download $file from any source (a partial download is kept as $part)"
}

default_variant() {
    case $1 in
        fedora)  echo workstation ;;
        ubuntu)  echo desktop ;;
        alpine)  echo standard ;;
        openbsd) echo install ;;
    esac
}

cmd_get_list() {
    local arch=$1 distro variant version a url sum display file mark
    echo "Available for $arch, last checked $(fmt_age "$(stat -f %m "$CATALOG")") (vmboot sync to refresh, -a for other architectures):"
    while IFS=$'\t' read -r distro variant version a url sum display; do
        [ "$a" = "$arch" ] || continue
        file=$(get_filename "$distro" "$a" "$url")
        mark=""
        [ -f "$SEARCH_DIR/$file" ] && mark="downloaded"
        [ "$variant" = "$(default_variant "$distro")" ] && mark="${mark:+$mark, }default"
        printf '  %-22s %-9s %-46s %s\n' "$distro/$variant" "$version" "$file" "${mark:+($mark)}"
    done < "$CATALOG"
}

# Local file name for a download: the release's own name, with the distro and
# arch added if they're not already in it (OpenBSD's is just install80.img).
get_filename() {
    local distro=$1 arch=$2 file
    file=$(basename "$3")
    case $(echo "$file" | tr '[:upper:]' '[:lower:]') in *"$distro"*) ;; *) file="$distro-$file" ;; esac
    arch_from_name "$file" >/dev/null || file="${file%.*}-$arch.${file##*.}"
    echo "$file"
}

cmd_get() {   # cmd_get [DISTRO[/VARIANT]]
    local arch=${opt_arch:-$(host_arch)} distro variant line version url sum display file
    ensure_catalog
    if [ -z "$1" ]; then
        cmd_get_list "$arch"
        return
    fi

    distro=$(echo "${1%%/*}" | tr '[:upper:]' '[:lower:]')
    case " $DISTROS " in *" $distro "*) ;; *) die "don't know how to get '$distro' (I know: $DISTROS)" ;; esac
    variant=${1#"${1%%/*}"}; variant=${variant#/}
    variant=${variant:-$(default_variant "$distro")}

    line=$(awk -F'\t' -v d="$distro" -v v="$variant" -v a="$arch" \
        '$1 == d && $2 == v && $4 == a { print; exit }' "$CATALOG")
    if [ -z "$line" ]; then
        echo "No $distro/$variant for $arch in the release list. What there is for $distro:" >&2
        awk -F'\t' -v d="$distro" '$1 == d { printf "  %s/%s (%s)\n", $1, $2, $4 }' "$CATALOG" >&2
        exit 1
    fi
    IFS=$'\t' read -r _ _ version _ url sum display <<<"$line"
    file=$(get_filename "$distro" "$arch" "$url")
    echo "$distro/$variant $version for $arch"

    download_image "$url" "$sum" "$file"
    [ $DOWNLOAD_ONLY -eq 0 ] || return 0
    echo
    known_arch=$arch
    opt_display=${opt_display:-$display}
    cmd_boot "" "$image_path"
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
    get)
        [ "$nargs" -le 1 ] || bad_usage "usage: vmboot get [options] [DISTRO[/VARIANT]]"
        cmd_get "$name"
        ;;
    sync)
        [ "$nargs" -eq 0 ] || bad_usage "usage: vmboot sync"
        cmd_sync
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
