#!/bin/bash
# Build the J7 Neo iOS root on macOS: one case-sensitive journaled HFS+ image
# holding the iPhone 8 iOS root filesystem plus its cryptexes, for the
# USERDATA partition (rd=mmcroot0).
#
#   tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [EXTRA]
#
# EXTRA is the free space added on top of the copied files (default 3g;
# hdiutil size syntax, e.g. 2500m, 4g). The image must stay at least
# 8 MiB smaller than the phone's USERDATA partition: the kernel keeps its
# console log in the last 4 MiB + 4 KiB of the partition, and
# tools/j7-flash.sh checks it. The disk image names come from the IPSW's
# BuildManifest.plist (OS, Cryptex1,SystemOS, Cryptex1,AppOS).
#
# macOS mounts the IPSW images itself (APFS); reading a compressed file
# through the mount returns its plain data, so rsync writes uncompressed
# files (the kernel has no AppleFSCompression). On a device
# /private/preboot is its own volume holding the cryptexes, which
# /System/Cryptexes/{OS,App} link to; here they live inside the one volume.
# Owners, modes, symlinks and hard links are preserved (rsync -aH as root,
# volumes attached with owners on).
#
# Additions: /System/Library/Caches/com.apple.dyld hard-links the SystemOS
# cryptex shared cache (ignition_level=1 looks there),
# /private/var/keybags/systembag.kb is the plain-plist system keybag that
# keybagd reads with /defaults/no-effaceable-storage (tools/mkadt.py), and
# tools/sweet-root-tweaks.py applies the bring-up changes at the end.
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,13p' "$0"; exit 2; }
[[ $(uname) == Darwin ]] || { echo "this script uses hdiutil: run it on macOS" >&2; exit 1; }
abspath() { (cd "$(dirname "$1")" && echo "$PWD/$(basename "$1")"); }
os=$(abspath "$1") sysos=$(abspath "$2") appos=$(abspath "$3") out=$4 extra=${5:-3g}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
attached=()
cleanup() {
	for (( i=${#attached[@]}-1; i>=0; i-- )); do
		hdiutil detach -quiet "${attached[$i]}" 2>/dev/null || hdiutil detach -force -quiet "${attached[$i]}" 2>/dev/null || true
	done
	rmdir "$work"/* "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Attach read-only at a mount point we choose; raw (cryptex) images need the raw class.
attach_ro() {
	local img=$1 mnt=$work/$2
	mkdir "$mnt"
	if ! hdiutil attach -readonly -nobrowse -owners on -mountpoint "$mnt" "$img" >/dev/null 2>&1; then
		hdiutil attach -readonly -nobrowse -owners on -mountpoint "$mnt" \
			-imagekey diskimage-class=CRawDiskImage "$img" >/dev/null
	fi
	attached+=("$mnt")
}
attach_ro "$os" os
attach_ro "$sysos" sysos
attach_ro "$appos" appos

# Size: what the three volumes hold, plus EXTRA.
used_k=$(sudo du -skx "$work/os" "$work/sysos" "$work/appos" | awk '{s += $1} END {print s}')
extra_k=$(python3 -c "import sys; v=sys.argv[1].lower(); m={'k':1,'m':1024,'g':1048576,'t':1073741824}; print(int(float(v[:-1])*m[v[-1]]) if v[-1] in m else int(v)//1024)" "$extra")
size_m=$(( (used_k + extra_k + 1023) / 1024 + 256 ))
echo "files: $((used_k / 1024)) MiB, image: $size_m MiB"

# Raw HFS+ volume, no partition map: -layout NONE, UDTO (raw) -> .cdr, renamed.
hdiutil create -quiet -size "${size_m}m" -layout NONE -fs "Case-sensitive Journaled HFS+" \
	-volname iOSRoot -type UDTO "$work/root-image"
mv "$work/root-image.cdr" "$out"
mkdir "$work/root"
hdiutil attach -nobrowse -owners on -mountpoint "$work/root" "$out" \
	-imagekey diskimage-class=CRawDiskImage >/dev/null
attached+=("$work/root")
sudo diskutil enableOwnership "$work/root" >/dev/null

copy() {
	echo "copying $1 -> ${2#"$work/root"}"
	sudo mkdir -p "$2"
	sudo rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$work/os" "$work/root"
copy "$work/sysos" "$work/root/private/preboot/Cryptexes/OS"
copy "$work/appos" "$work/root/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	sudo ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file that has no counterpart in the OS root (libobjc-trampolines,
# libffi-trampolines, libstdc++, ...) to its root path.
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$work/root/$f" && ! sudo test -L "$work/root/$f"; then
			sudo mkdir -p "$work/root/$(dirname "$f")"
			src="$work/root/private/preboot/Cryptexes/$c/$f"
			if sudo test -L "$src"; then sudo cp -P "$src" "$work/root/$f"; else sudo ln "$src" "$work/root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores, normally made at restore: it checks owner _logd (272)
# and mode, plus a .migrated marker, else asks a helper and crashes
# ("BUG IN LIBTRACE: Failed to migrate directory").
db="$work/root/private/var/db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
sudo install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
kb=$(mktemp)
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$kb"
sudo install -m 0600 -o 0 -g 0 "$kb" "$work/root/private/var/keybags/systembag.kb"
rm -f "$kb"

sudo python3 "$here/sweet-root-tweaks.py" "$work/root"

df -h "$work/root"
hdiutil detach -quiet "$work/root"
unset 'attached[${#attached[@]}-1]'

# Verify the volume (journal replay, catalog) on the detached image.
dev=$(hdiutil attach -nomount -nobrowse "$out" -imagekey diskimage-class=CRawDiskImage | awk 'NR==1{print $1}')
sudo fsck_hfs -f -y "$dev" || true
sudo fsck_hfs -f -n "$dev"
hdiutil detach -quiet "$dev"
ls -l "$out"
