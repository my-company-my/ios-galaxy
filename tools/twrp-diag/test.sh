#!/bin/bash
# Run iosgalaxy-diag.sh against a fake /sys (no phone): USB stays dead ->
# restart into Android; USB comes up after the MUIC switch -> stays in
# TWRP; no MUIC switch files -> reported, restart. SH=mksh (TWRP's shell)
# when installed, else sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SH=${SH:-$(command -v mksh || echo sh)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

mkroot() {	# dir, initial gadget state, [nosw]
	mkdir -p "$1/sys/class/android_usb/android0" "$1/sys/class/sec/switch" "$1/proc" "$1/tmp" "$1/sdcard" "$1/dev/usb-ffs/adb"
	echo "console=ram switch_sel=0x3 androidboot.mode=recovery" > "$1/proc/cmdline"
	local a="$1/sys/class/android_usb/android0"
	echo 1 > "$a/enable"; echo adb > "$a/functions"; echo "$2" > "$a/state"
	if [ "${3:-}" != nosw ]; then
		echo MODEM > "$1/sys/class/sec/switch/usb_sel"
		echo USB > "$1/sys/class/sec/switch/attached_dev"
	fi
}
run() {		# dir -> stdout file has REBOOT if the script restarted
	DIAG_ROOT="$1" DIAG_WAIT=12 DIAG_REBOOT="echo REBOOT" "$SH" "$here/iosgalaxy-diag.sh" > "$1/stdout" 2>&1
}
check() {
	if eval "$1"; then echo "ok    $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi
}

"$SH" -n "$here/iosgalaxy-diag.sh"
check '[ $? = 0 ]' "syntax ($SH)"

mkroot "$tmp/dead" DISCONNECTED
run "$tmp/dead"
r="$tmp/dead/tmp/iosgalaxy-twrp-diag.txt"
check 'grep -q REBOOT "$tmp/dead/stdout"' "USB dead: restarts into Android"
check 'grep -q "usb_sel = PDA" "$r"' "USB dead: tried usb_sel = PDA"
check '[ -f "$tmp/dead/sdcard/iosgalaxy-twrp-diag.txt" ]' "USB dead: report copied to /sdcard"
check 'grep -q "switch_sel=0x3" "$r"' "report has the kernel command line"

mkroot "$tmp/fixed" DISCONNECTED
( sleep 9; echo CONFIGURED > "$tmp/fixed/sys/class/android_usb/android0/state" ) &
run "$tmp/fixed"
wait
check '! grep -q REBOOT "$tmp/fixed/stdout"' "USB configured after the switch: stays in TWRP"
check 'grep -q "RESULT: USB configured" "$tmp/fixed/tmp/iosgalaxy-twrp-diag.txt"' "USB configured: reported"

mkroot "$tmp/nosw" DISCONNECTED nosw
run "$tmp/nosw"
check 'grep -q REBOOT "$tmp/nosw/stdout"' "no MUIC switch files: restarts"
check 'grep -q "no writable" "$tmp/nosw/tmp/iosgalaxy-twrp-diag.txt"' "no MUIC switch files: reported"

[ $fails = 0 ] && echo PASS || echo "$fails FAILED"
exit $fails
