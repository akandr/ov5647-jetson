#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
#
# Capture one JPEG through the ISP with a given override file, for
# score.py. Run as root on the board:
#
#   tools/isp/capture-isp.sh OVERRIDE|none OUT.jpg [SENSOR_ID] [MODE]
#
# Installs the override (or removes any for "none"), clears the cache,
# restarts nvargus-daemon and stops if Argus rejects a line of the file.
# Then it streams 50 frames, so that AE and AWB settle, and keeps the
# last one. The override that was installed before is put back at the
# end. ARGUS adds properties to nvarguscamerasrc, for example a fixed
# exposure for a bright scene in which AE would clip the chart:
#
#   ARGUS='exposuretimerange="300000 300000" gainrange="1 1"' tools/isp/capture-isp.sh ...
set -u

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
[ $# -ge 2 ] || { echo "usage: $0 OVERRIDE|none OUT.jpg [SENSOR_ID] [MODE]" >&2; exit 2; }
ovr=$1; out=$2; sid=${3:-0}; mode=${4:-2}

D=/var/nvidia/nvcam/settings
OVR=$D/camera_overrides.isp
SAVE=$(mktemp)
had=0
[ -e "$OVR" ] && { cp "$OVR" "$SAVE"; had=1; }
TMP=$(mktemp -d)

restore() {
	rm -f "$OVR" "$D"/nvcam_cache_*.bin
	[ "$had" = 1 ] && cp "$SAVE" "$OVR" && chmod 664 "$OVR"
	rm -rf "$SAVE" "$TMP"
	systemctl restart nvargus-daemon
}
trap restore EXIT

mkdir -p "$D"
rm -f "$OVR" "$D"/nvcam_cache_*.bin
[ "$ovr" = none ] || { cp "$ovr" "$OVR"; chmod 664 "$OVR"; }
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart nvargus-daemon
sleep 3

case $mode in
0) size="width=2592,height=1944,framerate=15/1" ;;
1) size="width=1920,height=1080,framerate=30/1" ;;
2) size="width=1296,height=972,framerate=30/1" ;;
3) size="width=640,height=480,framerate=90/1" ;;
4) size="width=1280,height=720,framerate=60/1" ;;
*) echo "mode 0 to 4" >&2; exit 2 ;;
esac
# The frame rate has to be in the caps, see the README.
eval "set -- ${ARGUS:-}"
timeout 60 gst-launch-1.0 -q nvarguscamerasrc sensor-id="$sid" sensor-mode="$mode" "$@" \
	num-buffers=50 ! "video/x-raw(memory:NVMM),$size" ! nvjpegenc quality=95 \
	! multifilesink location="$TMP/f-%03d.jpg" >/dev/null 2>&1

if journalctl -u nvargus-daemon --since "$since" --no-pager | grep -q "Bad parameter"; then
	echo "Argus rejected lines of $ovr:" >&2
	journalctl -u nvargus-daemon --since "$since" --no-pager |
		grep "Bad parameter" | sed 's/.*Line/  Line/' | sort -u >&2
	exit 1
fi
last=$(ls "$TMP"/f-*.jpg 2>/dev/null | tail -1)
[ -n "$last" ] || { echo "no frames; see journalctl -u nvargus-daemon" >&2; exit 1; }
cp "$last" "$out"
echo "$out"
