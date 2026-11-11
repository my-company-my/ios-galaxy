#!/bin/sh
# Host side of the phone's USB Ethernet (bsd/dev/sweet_usb.c), macOS or Linux.
#   tools/sweet-usbnet.sh [LOGFILE]
# Waits for the phone's CDC-ECM interface (host-side MAC 02:00:5e:77:ee:01),
# gives it 192.168.7.1/24 (the phone is 192.168.7.2), then prints the live
# kernel console the phone streams to UDP port 5140 (and appends it to
# LOGFILE if given). Needs sudo for the address.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") [LOGFILE]"
	echo "Wait for the phone's USB Ethernet interface and stream the live kernel UDP console."
	exit 0
fi

mac=02:00:5e:77:ee:01
echo "waiting for the phone's USB Ethernet ($mac)..." >&2
if [ "$(uname)" = Darwin ]; then
	# macOS: ifconfig lists "ether xx:..." under each interface.
	find_if() { ifconfig | awk -v m="$mac" '/^[a-z]/{i=$1; sub(":$","",i)} tolower($0) ~ "ether "m {print i}' | head -1; }
	until [ -n "$(find_if)" ]; do sleep 1; done
	ifname=$(find_if)
	sudo ifconfig "$ifname" inet 192.168.7.1 netmask 255.255.255.0 up
else
	until ip -o link | grep -qi "$mac"; do sleep 1; done
	ifname=$(ip -o link | grep -i "$mac" | awk -F': ' '{print $2}' | cut -d@ -f1)
	nmcli dev set "$ifname" managed no 2>/dev/null || true
	sudo ip addr replace 192.168.7.1/24 dev "$ifname"
	sudo ip link set "$ifname" up
fi
echo "$ifname up: 192.168.7.1 <-> phone 192.168.7.2; live log on udp/5140" >&2

listen_udp() {
	port=5140
	if command -v socat >/dev/null 2>&1; then
		socat -u "udp-recv:$port,reuseaddr" -
	elif [ "$(uname)" = Darwin ]; then
		nc -u -l -k "$port"
	elif nc -h 2>&1 | grep -q -- '-k'; then
		nc -ukl "$port"
	else
		while true; do
			nc -u -l -p "$port" 2>/dev/null || nc -u -l "$port" 2>/dev/null || break
		done
	fi
}

if [ $# -ge 1 ]; then
	listen_udp | tee -a "$1"
else
	listen_udp
fi
