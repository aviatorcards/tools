#!/bin/bash
# vmboot - pick an install ISO (or an existing VM) and boot it with QEMU.
#
# Usage: vmboot [-s search_dir] [-m memory] [-c cpus] [-z disk_size] [-g] [-t] [-n]
#   -s DIR   where to look for .iso/.img files (default: ~/Downloads)
#   -m MEM   guest RAM (default: 2G)
#   -c N     guest CPUs (default: 2)
#   -z SIZE  size of a newly created disk (default: 20G)
#   -g       graphical window instead of serial console in this terminal
#   -t       serial console in this terminal (default for arm64 guests)
#   -n       dry run: print the QEMU command instead of running it
#
# VMs (disk + saved arch) live in ~/VMs/<name>/. Pick a VM from the menu
# to boot its disk without an installer attached.

set -euo pipefail

SEARCH_DIR="$HOME/Downloads"
VM_ROOT="${VM_ROOT:-$HOME/VMs}"
MEM=2G
CPUS=2
DISK_SIZE=20G
DISPLAY_MODE=""
DRY_RUN=0

while getopts "s:m:c:z:gtnh" opt; do
    case $opt in
        s) SEARCH_DIR=$OPTARG ;;
        m) MEM=$OPTARG ;;
        c) CPUS=$OPTARG ;;
        z) DISK_SIZE=$OPTARG ;;
        g) DISPLAY_MODE=window ;;
        t) DISPLAY_MODE=terminal ;;
        n) DRY_RUN=1 ;;
        *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

die() { echo "vmboot: $*" >&2; exit 1; }

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

# ---- build the menu: images in SEARCH_DIR, then existing VMs ----
choices=()
labels=()
shopt -s nullglob nocaseglob
for f in "$SEARCH_DIR"/*.iso "$SEARCH_DIR"/*.img; do
    choices+=("image:$f")
    labels+=("$(basename "$f")  ($(du -h "$f" | cut -f1 | tr -d ' '), $(file -b "$f" | sed -n "s/.*'\(.*\)'.*/\1/p" | tr -s ' '))")
done
for d in "$VM_ROOT"/*/; do
    [ -f "$d/disk.qcow2" ] || continue
    choices+=("vm:${d%/}")
    labels+=("[VM] $(basename "$d")  (boot installed disk, $(cat "$d/arch" 2>/dev/null || echo '?'))")
done
shopt -u nullglob nocaseglob

[ ${#choices[@]} -gt 0 ] || die "no .iso/.img files in $SEARCH_DIR and no VMs in $VM_ROOT"

echo "Choose something to boot:"
PS3="> "
select _ in "${labels[@]}"; do
    [ -n "${REPLY:-}" ] && [ "$REPLY" -ge 1 ] 2>/dev/null && [ "$REPLY" -le ${#choices[@]} ] && break
    echo "Pick a number from 1 to ${#choices[@]}."
done
choice=${choices[$((REPLY - 1))]}

# ---- work out the image, VM directory and architecture ----
image=""
case $choice in
    image:*)
        image=${choice#image:}
        arch=$(detect_arch "$image")
        if [ -z "$arch" ]; then
            echo "Couldn't detect the architecture of $(basename "$image")."
            select arch in arm64 amd64 i386; do [ -n "$arch" ] && break; done
        else
            echo "Detected architecture: $arch"
        fi
        default_name="$(basename "${image%.*}")-$arch"
        read -r -p "VM name [$default_name]: " vm_name
        vm_dir="$VM_ROOT/${vm_name:-$default_name}"
        ;;
    vm:*)
        vm_dir=${choice#vm:}
        arch=$(cat "$vm_dir/arch" 2>/dev/null || true)
        [ -n "$arch" ] || die "$vm_dir/arch is missing; can't tell which QEMU to use"
        ;;
esac

disk="$vm_dir/disk.qcow2"
if [ ! -f "$disk" ]; then
    echo "Creating $DISK_SIZE disk at $disk"
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$vm_dir"
        qemu-img create -q -f qcow2 "$disk" "$DISK_SIZE"
        echo "$arch" > "$vm_dir/arch"
    fi
fi

# ---- pick the QEMU binary, machine and accelerator ----
host=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel Macs
qemu_share="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)/share/qemu"
args=()

case $arch in
    arm64)
        qemu=qemu-system-aarch64
        args+=(-M virt -bios "$qemu_share/edk2-aarch64-code.fd")
        if [ "$host" = arm64 ]; then
            args+=(-accel hvf -cpu host)
        else
            args+=(-accel tcg -cpu max)
            echo "Note: arm64 guest on an Intel Mac runs under emulation (slow)."
        fi
        ;;
    amd64|i386)
        [ "$arch" = amd64 ] && qemu=qemu-system-x86_64 || qemu=qemu-system-i386
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

args+=(-m "$MEM" -smp "$CPUS")
args+=(-drive "file=$disk,if=virtio,format=qcow2")
args+=(-nic "user,model=virtio-net-pci")

if [ -n "$image" ]; then
    case $image in
        *.iso|*.ISO) args+=(-drive "file=$image,media=cdrom,readonly=on") ;;
        # .img installers (e.g. OpenBSD's install*.img) are disk images, not CDs
        *) args+=(-drive "file=$image,if=virtio,format=raw,readonly=on") ;;
    esac
fi

# arm64 firmware and boot loaders talk to the serial port, so the terminal is
# the natural default there; x86 installers usually expect a screen.
if [ -z "$DISPLAY_MODE" ]; then
    [ "$arch" = arm64 ] && DISPLAY_MODE=terminal || DISPLAY_MODE=window
fi
if [ "$DISPLAY_MODE" = terminal ]; then
    args+=(-nographic)
    echo "Serial console in this terminal. Quit QEMU with Ctrl-A then X."
    [ "$arch" != arm64 ] && echo "Tip: if output stops after the boot loader, type 'set tty com0' at the boot> prompt."
else
    args+=(-display cocoa)
    [ "$arch" = arm64 ] && args+=(-device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet)
fi

echo
echo "$qemu ${args[*]}"
echo
[ $DRY_RUN -eq 1 ] && exit 0
exec "$qemu" "${args[@]}"
