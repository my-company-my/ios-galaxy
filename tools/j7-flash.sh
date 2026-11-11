#!/bin/sh
# Galaxy J7 Neo (SM-J701M) partitions over ADB from TWRP (macOS or Linux).
#
#   tools/j7-flash.sh backup DIR        copy BOOT, RECOVERY, EFS, CPEFS?, PARAM, RADIO... to DIR
#   tools/j7-flash.sh boot IMG          write IMG (shim/out/shim-boot.img) to BOOT
#   tools/j7-flash.sh root IMG          write IMG (tools/mkiosroot.sh) to the start of USERDATA
#   tools/j7-flash.sh info              partition table and sizes
#
# The phone must be in TWRP (Volume up + Home + Power from power-off) with
# ADB working (`adb devices` shows it as "recovery"). Install TWRP once
# from Download mode with Heimdall (`heimdall flash --RECOVERY twrp.img
# --no-reboot`, then boot straight into recovery) or Odin.
#
# Writes go only to BOOT or USERDATA, after checking that the image fits:
# USERDATA keeps its last 8 MiB free for the kernel's console log ring
# (bsd/dev/sweet_mmc.c). Everything Android had in USERDATA is lost.
set -eu

ADB=${ADB:-adb}
command -v "$ADB" >/dev/null 2>&1 || { echo "adb not found (macOS: brew install android-platform-tools)" >&2; exit 1; }

usage() { sed -n '2,17p' "$0"; exit 2; }
[ $# -ge 1 ] || usage

state=$($ADB get-state 2>/dev/null || true)
[ "$state" = recovery ] || { echo "phone not in recovery over adb (state: ${state:-none})" >&2; exit 1; }

# Block device of a partition by its GPT name (Exynos: upper case), any case.
part() {
	$ADB shell "for d in /dev/block/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
		for p in \$d/*; do n=\${p##*/}; [ \"\$(echo \$n | tr a-z A-Z)\" = \"$1\" ] && readlink -f \$p && exit 0; done; done" |
		tr -d '\r' | head -1
}
psize() { $ADB shell blockdev --getsize64 "$1" | tr -d '\r'; }
fsize() { wc -c < "$1" | tr -d ' '; }

case $1 in
info)
	$ADB shell 'ls -l /dev/block/platform/*/by-name/ 2>/dev/null || ls -l /dev/block/by-name/'
	for p in BOOT RECOVERY USERDATA; do d=$(part $p); [ -n "$d" ] && echo "$p $d $(psize "$d") bytes"; done
	;;
backup)
	dir=${2:?backup DIR}
	mkdir -p "$dir"
	for p in BOOT RECOVERY EFS CPEFS PARAM RADIO PERSISTENT STEADY SBOOT CM; do
		d=$(part $p)
		[ -n "$d" ] || { echo "skip $p (not on this phone)"; continue; }
		echo "$p <- $d"
		$ADB exec-out "dd if=$d bs=1048576 2>/dev/null" > "$dir/$p.img"
		[ "$(fsize "$dir/$p.img")" = "$(psize "$d")" ] || { echo "size mismatch for $p" >&2; exit 1; }
	done
	(cd "$dir" && shasum -a 256 ./*.img > SHA256SUMS)
	echo "keep $dir safe (EFS holds the IMEI and calibration). For the shim build: cp $dir/BOOT.img dtb/stock-boot.img"
	;;
boot)
	img=${2:?boot IMG}
	d=$(part BOOT)
	[ -n "$d" ] || { echo "no BOOT partition" >&2; exit 1; }
	[ "$(fsize "$img")" -le "$(psize "$d")" ] || { echo "$img larger than BOOT ($(psize "$d") bytes)" >&2; exit 1; }
	echo "BOOT $d <- $img"
	$ADB exec-in "dd of=$d bs=1048576 2>/dev/null" < "$img"
	$ADB shell sync
	echo "done. adb reboot"
	;;
root)
	img=${2:?root IMG}
	d=$(part USERDATA)
	[ -n "$d" ] || { echo "no USERDATA partition" >&2; exit 1; }
	have=$(psize "$d") need=$(fsize "$img")
	[ $((need + 8 * 1048576)) -le "$have" ] || { echo "$img ($need bytes) + 8 MiB log area does not fit USERDATA ($have bytes): rebuild with a smaller EXTRA" >&2; exit 1; }
	printf 'This erases Android user data on %s (%s bytes). Type ERASE: ' "$d" "$have"
	read -r answer
	[ "$answer" = ERASE ] || exit 1
	$ADB shell 'umount /data 2>/dev/null; umount /sdcard 2>/dev/null; true'
	echo "USERDATA $d <- $img ($((need / 1048576)) MiB, several minutes)"
	$ADB exec-in "dd of=$d bs=4194304 2>/dev/null" < "$img"
	$ADB shell sync
	# Clear the log area so an old ring is never mistaken for a new one.
	$ADB shell "dd if=/dev/zero of=$d bs=512 seek=$((have / 512 - 8200)) count=8200 2>/dev/null; sync"
	echo "done"
	;;
*) usage ;;
esac
