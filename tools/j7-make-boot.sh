#!/bin/bash
# Build the J7 Neo boot image from a kernel: ADT, payload, shim, boot.img.
#
#   tools/j7-make-boot.sh KERNEL [--cpus N] [--payload-in-kernel] [--extra "boot-args"]
#
# KERNEL is kernel.development.sweet from the xnu CI artifact (xnu/out/).
# Needs dtb/stock-boot.img (tools/j7-flash.sh backup) and, for the iPhone 8
# identity, research/ipsw-8/d201ap.adt (README step 3). Output:
# shim/out/shim-boot.img, ready for tools/j7-flash.sh boot.
set -euo pipefail
cd "$(dirname "$0")/.."

kernel=${1:?usage: tools/j7-make-boot.sh KERNEL [--cpus N] [--payload-in-kernel] [--extra "boot-args"]}
shift
cpus=1
extra=""
shim_args=()
while [ $# -gt 0 ]; do
	case $1 in
	--cpus) cpus=$2; shift ;;
	--extra) extra=$2; shift ;;
	--payload-in-kernel) shim_args+=(--payload-in-kernel) ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done
[ -f research/ipsw-8/d201ap.adt ] || echo "warning: no research/ipsw-8/d201ap.adt: the ADT gets no /product (README step 3)" >&2

# Boot-args (README "Boot-args"): root on USERDATA read-write, console log
# kept in the partition, no watchdogs, kernel text off the GUI once it runs.
args="debug=0xc serial=3 cpus=$cpus keepsyms=1 -enable_kprintf_spam -noprogress"
args="$args rd=mmcroot0 mmcrw=1 rootrw=1 unentitled_ios_sim_launch=1 ignition_level=1"
args="$args wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=20"
[ -n "$extra" ] && args="$args $extra"

mkdir -p shim/out
python3 tools/mkadt.py shim/out/j7neo.adt
python3 tools/mkpayload.py "$kernel" shim/out/j7neo.adt shim/out/payload.bin --cmdline "$args"
bash shim/build.sh shim/out/payload.bin "${shim_args[@]}"
echo "boot-args: $args"
