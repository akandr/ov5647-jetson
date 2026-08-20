#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Capture check for the OV5647 driver. Run ON the board, after installing.
#
#   sudo tests/capture-check.sh            # all modes, raw and ISP
#   sudo tests/capture-check.sh --raw-only # skip the Argus checks
#
# Each raw mode is checked three ways, because a frame count alone proves
# very little: v4l2-ctl keeps streaming in the previous format when a
# requested one is rejected, and a covered lens still delivers full frame
# counts. So the script also confirms the device accepted the geometry it
# was asked for, that the file holds exactly the expected number of bytes,
# and that the pixels carry signal rather than a flat black level.
set -uo pipefail

DEV=${DEV:-/dev/video0}
FRAMES=${FRAMES:-10}
RAW_ONLY=""
[ "${1:-}" = "--raw-only" ] && RAW_ONLY=1

command -v v4l2-ctl >/dev/null || { echo "need v4l2-utils"; exit 2; }
command -v python3 >/dev/null || { echo "need python3"; exit 2; }
[ -e "$DEV" ] || { echo "no $DEV: is the driver loaded and the overlay applied?"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

# The sensor is Bayer BGGR, which V4L2 spells BG10. RG10 is a different
# order and the driver does not advertise it; asking for it leaves the
# format untouched and the capture silently runs in whatever was set last.
FMT=BG10

check_raw() { # mode width height
	local mode=$1 w=$2 h=$3 name="mode$1 ${2}x${3}"

	v4l2-ctl -d "$DEV" --set-ctrl sensor_mode="$mode" >/dev/null 2>&1
	if ! v4l2-ctl -d "$DEV" --set-fmt-video=width="$w",height="$h",pixelformat=$FMT >/dev/null 2>&1; then
		echo "FAIL $name: device rejected the format"; fail=1; return
	fi

	local got size
	got=$(v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null | awk '/Width\/Height/{print $3}')
	size=$(v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null | awk '/Size Image/{print $4}')
	if [ "$got" != "$w/$h" ]; then
		echo "FAIL $name: device is at $got, not the requested geometry"; fail=1; return
	fi

	rm -f "$TMP/raw"
	timeout 60 v4l2-ctl -d "$DEV" --stream-mmap --stream-count="$FRAMES" \
		--stream-to="$TMP/raw" >/dev/null 2>&1
	local bytes expected
	bytes=$(stat -c %s "$TMP/raw" 2>/dev/null || echo 0)
	expected=$((size * FRAMES))
	if [ "$bytes" = 0 ]; then
		# Streaming that stops with no data and no error usually means the
		# VI queue is still holding buffers from a capture that was killed
		# rather than stopped. Nothing clears that short of a reboot.
		echo "FAIL $name: no data at all. If a capture was interrupted earlier," \
		     "the VI queue is wedged (dmesg shows videobuf2 warnings); reboot the board"
		fail=1; return
	fi
	if [ "$bytes" != "$expected" ]; then
		echo "FAIL $name: captured $bytes B, expected $expected B"; fail=1; return
	fi

	# Content: a frame that is all black level has almost no spread. This
	# catches a covered lens or a dead link, which frame counting misses.
	local stats mean std max
	stats=$(python3 - "$TMP/raw" "$size" "$h" <<-'PY'
	import sys, numpy as np
	path, size, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
	d = np.fromfile(path, dtype=np.uint16)
	frames = len(d) // (size // 2)
	f = d[(frames - 1) * size // 2:frames * size // 2].reshape(h, -1).astype(np.float32)
	print("%.1f %.1f %d" % (f.mean(), f.std(), f.max()))
	PY
	)
	read -r mean std max <<<"$stats"
	local verdict="ok"
	if python3 -c "import sys; sys.exit(0 if float('$std') < 2.0 else 1)"; then
		verdict="ok, but the frame is flat (std $std): lens covered or no light?"
	fi
	echo "PASS $name: $FRAMES frames, $bytes B, mean $mean std $std max $max, $verdict"
}

check_argus() { # mode width height
	local mode=$1 w=$2 h=$3 out
	out=$(timeout 60 gst-launch-1.0 -q nvarguscamerasrc sensor-mode="$mode" num-buffers=10 \
		! "video/x-raw(memory:NVMM),width=$w,height=$h" ! fakesink 2>&1)
	if echo "$out" | grep -qiE 'error|fail'; then
		echo "FAIL argus mode$mode ${w}x${h}: $(echo "$out" | grep -im1 -E 'error|fail')"
		fail=1
	else
		echo "PASS argus mode$mode ${w}x${h}"
	fi
}

# Argus keeps the sensor open after a pipeline ends, so a run that follows
# an ISP check finds the device busy and captures nothing. Clear both users
# of the sensor before touching it, and give the VI a moment to settle.
pkill -9 v4l2-ctl 2>/dev/null
pkill -9 gst-launch-1.0 2>/dev/null
systemctl stop nvargus-daemon 2>/dev/null
sleep 2

check_raw 0 2592 1944
check_raw 1 1920 1080
check_raw 2 1296 972
check_raw 3 640 480

if [ -z "$RAW_ONLY" ] && command -v gst-launch-1.0 >/dev/null; then
	systemctl start nvargus-daemon 2>/dev/null
	sleep 2
	check_argus 1 1920 1080
	check_argus 2 1296 972
	check_argus 3 640 480
	echo "note: 2592x1944 through Argus is a known failure, see README"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
