#!/sbin/sh
# iOS Galaxy diagnostic for TWRP on the J7 Neo (added by tools/twrp-diag.py).
#
# On the SM-J701M this TWRP shows up on no computer: no USB device at all.
# This writes a report (USB gadget, Samsung MUIC switch, kernel messages),
# tries to route USB to the AP through the MUIC driver, and then:
#   - if a computer configured the USB gadget, TWRP stays (adb works);
#   - otherwise, 90 s after start, it restarts into Android, so a phone
#     without a working power button (and no touch in TWRP) is never stuck.
# Report: /sdcard/iosgalaxy-twrp-diag.txt (Android: Internal storage),
# also /cache/recovery/ and /tmp/. Only reads, except the MUIC usb_sel
# switch and the gadget enable bit; never touches partitions.
#
# DIAG_ROOT / DIAG_REBOOT / DIAG_WAIT let tools/twrp-diag-test.sh run it
# against a fake /sys on a computer.
R=${DIAG_ROOT:-}
REBOOT=${DIAG_REBOOT:-reboot}
WAIT=${DIAG_WAIT:-90}
A=$R/sys/class/android_usb/android0
SW=$R/sys/class/sec/switch
OUT=$R/tmp/iosgalaxy-twrp-diag.txt
start=$(date +%s)

say() {
	echo "$*" >> "$OUT"
	[ -z "$R" ] && echo "iosgalaxy-diag: $*" > /dev/kmsg
}
show() {
	for f in "$@"; do
		[ -e "$f" ] && echo "  $f = $(cat "$f" 2>&1)" >> "$OUT"
	done
}
switches() {
	for f in "$SW"/*; do
		[ -f "$f" ] && [ -r "$f" ] && echo "  $f = $(cat "$f" 2>&1)" >> "$OUT"
	done
}
configured() {
	[ "$(cat "$A/state" 2>/dev/null)" = CONFIGURED ]
}
elapsed() {
	echo $(( $(date +%s) - start ))
}
save() {
	sync
	for d in "$R/sdcard" "$R/data/media/0" "$R/cache/recovery"; do
		[ -d "$d" ] && cp "$OUT" "$d/iosgalaxy-twrp-diag.txt" 2>/dev/null && say "report copied to $d"
	done
	sync
}

mkdir -p "$(dirname "$OUT")"
echo "== iOS Galaxy TWRP diagnostic $(date)" > "$OUT"
say "cmdline: $(cat "$R/proc/cmdline" 2>&1)"
sleep 5

say "--- 1. USB gadget and MUIC as TWRP left them"
show "$A/enable" "$A/functions" "$A/state" "$A/idVendor" "$A/idProduct"
switches
getprop 2>/dev/null | grep -E 'usb|adb|ffs|ro.boot.(mode|bootloader|hardware)' >> "$OUT"
ls -la "$R/dev/usb-ffs/adb" >> "$OUT" 2>&1
ps -A 2>/dev/null | grep -E 'adbd|recovery' >> "$OUT"

if ! configured; then
	say "--- 2. route USB to the AP (usb_sel = PDA) and restart the gadget"
	if [ -w "$SW/usb_sel" ]; then
		echo PDA > "$SW/usb_sel" 2>> "$OUT" || say "usb_sel write failed"
	else
		say "no writable $SW/usb_sel"
	fi
	echo 0 > "$A/enable" 2>> "$OUT"
	sleep 1
	echo 1 > "$A/enable" 2>> "$OUT"
	sleep 8
	show "$A/state" "$SW/usb_sel" "$SW/attached_dev" "$SW/usb_state"
fi

while ! configured && [ "$(elapsed)" -lt "$WAIT" ]; do
	sleep 5
done

say "--- 3. after $(elapsed) s"
show "$A/enable" "$A/functions" "$A/state"
switches
say "--- kernel messages (usb, muic, s2mu005, android_usb, dwc3, ffs)"
dmesg 2>/dev/null | grep -iE 'usb|muic|s2mu005|android|dwc3|ffs|udc|gadget|vbus|switch_sel' | tail -n 300 >> "$OUT"

if configured; then
	say "RESULT: USB configured by a computer: staying in TWRP (adb should work)"
	save
	exit 0
fi
say "RESULT: no computer configured USB within $WAIT s: restarting into Android"
save
$REBOOT
