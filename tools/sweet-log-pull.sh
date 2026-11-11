#!/bin/sh
# Read the kernel's console log (bsd/dev/sweet_mmc.c) from a Galaxy J7 Neo
# booted into TWRP (adb in recovery). macOS or Linux.
#   tools/sweet-log-pull.sh [-s SERIAL] OUT.txt
# Only reads: the last 4 MiB + 4 KiB (8200 sectors) of USERDATA.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") [-s SERIAL] OUT.txt"
	echo "Pull the 4 MiB kernel log ring from USERDATA via recovery ADB."
	exit 0
fi

ADB="adb"
if [ "${1:-}" = "-s" ]; then
	shift
	SERIAL=${1:?Error: -s requires a device serial}
	shift
	ADB="adb -s $SERIAL"
fi

out=${1:?usage: sweet-log-pull.sh [-s SERIAL] OUT.txt}
command -v adb >/dev/null 2>&1 || { echo "Error: adb not found (macOS: brew install android-platform-tools)" >&2; exit 1; }

dev=$($ADB shell 'for d in /dev/block/by-name /dev/block/platform/*/by-name; do for p in $d/USERDATA $d/userdata; do [ -e $p ] && readlink -f $p && exit 0; done; done' 2>/dev/null | tr -d '\r')
[ -n "$dev" ] || { echo "USERDATA block device not found on connected device" >&2; exit 1; }
bytes=$($ADB shell blockdev --getsize64 "$dev" | tr -d '\r')
skip=$((bytes / 512 - 8200))
$ADB exec-out "dd if=$dev bs=512 skip=$skip count=8200 2>/dev/null" > "$out.bin"
echo "$dev: $bytes bytes, read sectors $skip.. ($(wc -c < "$out.bin" | tr -d ' ') bytes)" >&2
python3 "$(dirname "$0")/sweet-log.py" "$out.bin" "$out"
