#!/bin/bash
# Build the J7 Neo shim and wrap it in a Samsung (S-BOOT) boot image.
#
#   shim/build.sh [PAYLOAD] [--payload-in-kernel]
#
# Works on macOS (Homebrew: brew install llvm lld) and Linux (clang, lld).
# PAYLOAD (tools/mkpayload.py output) goes into the boot image ramdisk;
# with --payload-in-kernel it is appended to the shim Image instead (use
# that if the shim reports "INITRD none in /chosen"). Without PAYLOAD the
# ramdisk is an empty cpio and the shim only shows its CPU checks.
#
# The header fields (base, offsets, page size, os_version, board name) and
# the device tree blob (dt.img) are taken from the phone's stock boot
# image: dtb/stock-boot.img (see README, "Back up the phone").
# SHIM_IMAGE_ONLY=1 builds out/Image without it (CI, QEMU tests).
set -euo pipefail
cd "$(dirname "$0")"

PAYLOAD=""
IN_KERNEL=0
for a in "$@"; do
	case "$a" in
	--payload-in-kernel) IN_KERNEL=1 ;;
	*) PAYLOAD="$a" ;;
	esac
done

# Toolchain: Homebrew LLVM on macOS (Apple's clang has no ld.lld), else PATH.
if [ "$(uname)" = Darwin ] && command -v brew >/dev/null; then
	for f in llvm lld; do
		p=$(brew --prefix "$f" 2>/dev/null || true)
		[ -n "$p" ] && PATH="$p/bin:$PATH"
	done
fi
CC=${CC:-clang}
for t in "$CC" ld.lld llvm-objcopy llvm-nm llvm-readelf; do
	command -v "$t" >/dev/null || { echo "error: $t not found (macOS: brew install llvm lld)" >&2; exit 1; }
done

CFLAGS="--target=aarch64-none-elf -O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
SRCS="start.S shim.c console.c fdt.c loader.c"
mkdir -p out
OBJS=""
for f in $SRCS; do
	"$CC" $CFLAGS -c "$f" -o "out/${f%.*}.o"
	OBJS="$OBJS out/${f%.*}.o"
done
# The image runs wherever S-BOOT puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$(llvm-readelf -r out/shim.o out/console.o out/fdt.o out/loader.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
ld.lld -T shim.ld --build-id=none -N -static $OBJS -o out/shim.elf
llvm-objcopy -O binary out/shim.elf out/Image
# Pad to image_size so .bss/stacks exist as zeroed bytes.
size=$(llvm-nm out/shim.elf | awk '$3=="_end"{print $1}')
python3 - out/Image "$size" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2], 16)
data = open(path, 'rb').read()
assert len(data) <= size, (len(data), size)
open(path, 'wb').write(data + b'\0' * (size - len(data)))
PY

RAMDISK_ARGS=(--empty-ramdisk)
if [ -n "$PAYLOAD" ]; then
	if [ "$IN_KERNEL" = 1 ]; then
		# Behind the padded Image, 4 KiB aligned (loader.c find_payload).
		python3 - out/Image "$PAYLOAD" <<'PY'
import sys
img, payload = sys.argv[1], sys.argv[2]
data = open(img, 'rb').read()
data += b'\0' * (-len(data) % 4096)
open(img, 'wb').write(data + open(payload, 'rb').read())
PY
	else
		RAMDISK_ARGS=(--ramdisk "$PAYLOAD")
	fi
fi
if [ -f ../dtb/stock-boot.img ]; then
	python3 ../tools/mkbootimg_samsung.py --stock ../dtb/stock-boot.img --kernel out/Image \
		"${RAMDISK_ARGS[@]}" -o out/shim-boot.img
elif [ "${SHIM_IMAGE_ONLY:-0}" = 1 ]; then
	echo "SHIM_IMAGE_ONLY=1: out/Image only (no dtb/stock-boot.img)"
else
	echo "error: dtb/stock-boot.img missing (copy of the phone's BOOT partition; tools/j7-flash.sh backup)" >&2
	exit 1
fi
# Host render of the console layout (any C compiler for the host).
if command -v cc >/dev/null; then
	cc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
fi
ls -l out/Image out/shim-boot.img 2>/dev/null || ls -l out/Image
