#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
#
# Find which values Argus accepts for override keys. Run as root on the
# board, with a camera attached:
#
#   tools/isp/probe-keys.sh 'awb.v4.HighU = 2.0;' 'awb.v4.HighU = 5.0;'
#
# Every argument becomes one line of a temporary camera_overrides.isp.
# Argus parses all lines and logs each one it rejects, so one daemon
# start tests many values at once. The script prints ACCEPTED or
# REJECTED per line and then puts back the override that was there
# before, if any.
#
# A rejected line stops the camera, so the test pipeline is expected to
# fail whenever anything is rejected.
set -u

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
[ $# -gt 0 ] || { echo "usage: $0 'key = value;' ..." >&2; exit 2; }

D=/var/nvidia/nvcam/settings
OVR=$D/camera_overrides.isp
SAVE=$(mktemp)
had=0
[ -e "$OVR" ] && { cp "$OVR" "$SAVE"; had=1; }

restore() {
	rm -f "$OVR" "$D"/nvcam_cache_*.bin
	[ "$had" = 1 ] && cp "$SAVE" "$OVR" && chmod 664 "$OVR"
	rm -f "$SAVE"
	systemctl restart nvargus-daemon
}
trap restore EXIT

mkdir -p "$D"
printf '%s\n' "$@" > "$OVR"
chmod 664 "$OVR"
rm -f "$D"/nvcam_cache_*.bin
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart nvargus-daemon
sleep 3
# The override is parsed when a camera is opened.
timeout 20 gst-launch-1.0 -q nvarguscamerasrc sensor-id=0 num-buffers=2 ! fakesink \
	>/dev/null 2>&1
sleep 1
log=$(journalctl -u nvargus-daemon --since "$since" --no-pager)

n=0
for line in "$@"; do
	n=$((n + 1))
	if printf '%s\n' "$log" | grep -q "Line $n: Error: Bad parameter"; then
		echo "REJECTED  $line"
	else
		echo "ACCEPTED  $line"
	fi
done
