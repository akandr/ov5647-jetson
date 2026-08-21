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
	local err
	if ! err=$(v4l2-ctl -d "$DEV" --set-fmt-video=width="$w",height="$h",pixelformat=$FMT 2>&1); then
		if echo "$err" | grep -qi busy; then
			# fuser lists nothing for another user's process unless we are
			# root, so a busy device can look like it has no owner at all.
			echo "FAIL $name: $DEV is busy, another process still has it open" \
			     "(run as root to see which: fuser -v $DEV)"
		else
			echo "FAIL $name: device rejected the format: $(echo "$err" | head -1)"
		fi
		fail=1; return
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
		local h
		h=$(holders)
		if [ -n "$h" ]; then
			echo "FAIL $name: no data, $DEV is held by pid(s) $h:"
			ps -o pid=,user=,args= -p $h 2>/dev/null | sed 's/^/    /'
		else
			echo "FAIL $name: streaming returned no data and nothing else holds $DEV"
		fi
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

# A capture that produces nothing almost always means something else still
# has the device open, not that the hardware needs a reboot. The usual
# sources are Argus, which keeps the sensor open after a pipeline ends, and
# a capture whose kill landed on a `timeout` wrapper instead of v4l2-ctl
# itself, leaving an orphan streaming under init. An orphan started under
# sudo also survives an unprivileged pkill without reporting an error.
holders() { # names whatever still has the device open
	fuser "$DEV" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}
free_device() {
	pkill -9 v4l2-ctl 2>/dev/null
	pkill -9 gst-launch-1.0 2>/dev/null
	systemctl stop nvargus-daemon 2>/dev/null
	sleep 2
	local h
	h=$(holders)
	[ -z "$h" ] && return 0
	echo "$DEV is still held by pid(s) $h after cleanup:"
	ps -o pid=,user=,args= -p $h 2>/dev/null | sed 's/^/  /'
	echo "run this script as root, or kill those first"
	return 1
}

free_device || exit 2

# An Argus pipeline leaves the raw V4L2 path returning nothing at all: the
# sensor keeps streaming (0x0100 still reads 1 and the mode registers are
# unchanged) but the frames stop reaching userspace, and the kernel logs
# __vb2_queue_cancel warnings about buffers the VI channel never returned.
# Rebinding the sensor driver tears the channel down and rebuilds it, which
# clears the state without a reboot. Same behaviour on R32 and R35.
recover_sensor() {
	local drv=/sys/bus/i2c/drivers/ov5647 dev
	dev=$(ls "$drv" 2>/dev/null | grep -E '^[0-9]+-[0-9a-f]+$' | head -1)
	[ -n "$dev" ] || return 1
	echo "$dev" > "$drv/unbind" 2>/dev/null || return 1
	sleep 2
	echo "$dev" > "$drv/bind" 2>/dev/null || return 1
	sleep 3
	[ -e "$DEV" ]
}

raw_alive() {
	rm -f "$TMP/live.raw"
	timeout 30 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=3 \
		--stream-to="$TMP/live.raw" >/dev/null 2>&1
	[ -s "$TMP/live.raw" ]
}

if ! raw_alive; then
	echo "raw capture returns nothing, most likely after an earlier Argus run;"
	echo "rebinding the sensor driver"
	if recover_sensor && raw_alive; then
		echo "  recovered"
	else
		echo "  still no data after rebinding: this is not the Argus case"
		exit 2
	fi
fi

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
	# Leave the board usable: the raw path is dead until the driver is
	# rebound, so a second run of this script would otherwise fail.
	systemctl stop nvargus-daemon 2>/dev/null
	if recover_sensor; then
		echo "note: rebound the sensor driver, which the raw path needs after Argus"
	else
		echo "note: could not rebind the sensor driver; raw capture stays dead until reboot"
	fi
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
