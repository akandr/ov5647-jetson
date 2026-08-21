#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Control check for the OV5647 driver. Run ON the board, after installing.
#
#   sudo tests/control-check.sh
#
# capture-check.sh proves frames arrive with the right geometry and some
# content. It says nothing about whether exposure, gain and frame rate
# reach the sensor, which is a separate way for a camera driver to be
# broken: streaming looks perfect while every control is ignored.
#
# Two rules decide how this script measures, and both were learned the
# hard way:
#
#   - Controls are set WHILE streaming. With override_enable=0, which is
#     the default, tegracam does not apply values that were set before
#     the stream started, so a sweep done that way shows a flat line and
#     looks like a driver bug.
#   - Frame rate is measured inside ONE stream, counting frames in a
#     time window. Every stream start rewrites the nominal frame length,
#     so timing separate short streams always reports the mode default.
set -uo pipefail

DEV=${DEV:-/dev/video0}
MODE=${MODE:-2}
W=${W:-1296}
H=${H:-972}

command -v v4l2-ctl >/dev/null || { echo "need v4l2-utils"; exit 2; }
command -v python3 >/dev/null || { echo "need python3"; exit 2; }
[ -e "$DEV" ] || { echo "no $DEV: is the driver loaded and the overlay applied?"; exit 2; }

TMP=$(mktemp -d)
trap 'pkill -9 v4l2-ctl 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0

# Nothing here works while another process still has the device open, and
# the usual culprit is an orphaned capture: a kill that hit a `timeout`
# wrapper rather than v4l2-ctl, or an unprivileged pkill against a stream
# that was started under sudo, which fails silently.
pkill -9 v4l2-ctl 2>/dev/null
systemctl stop nvargus-daemon 2>/dev/null
sleep 2
held=$(fuser "$DEV" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')
if [ -n "$held" ]; then
	echo "$DEV is still held by pid(s) $held after cleanup:"
	ps -o pid=,user=,args= -p $held 2>/dev/null | sed 's/^/  /'
	echo "run this script as root, or kill those first"
	exit 2
fi

# After any Argus pipeline the raw path returns nothing until the sensor
# driver is rebound: the sensor still streams, but the VI channel stops
# handing frames over. Rebinding rebuilds the channel, no reboot needed.
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

v4l2-ctl -d "$DEV" --set-ctrl sensor_mode=$MODE >/dev/null 2>&1
v4l2-ctl -d "$DEV" --set-fmt-video=width=$W,height=$H,pixelformat=BG10 >/dev/null 2>&1
rm -f "$TMP/live.raw"
timeout 30 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=3 \
	--stream-to="$TMP/live.raw" >/dev/null 2>&1
if [ ! -s "$TMP/live.raw" ]; then
	echo "raw capture returns nothing, rebinding the sensor driver"
	recover_sensor || { echo "  rebinding failed"; exit 2; }
	v4l2-ctl -d "$DEV" --set-ctrl sensor_mode=$MODE >/dev/null 2>&1
	v4l2-ctl -d "$DEV" --set-fmt-video=width=$W,height=$H,pixelformat=BG10 >/dev/null 2>&1
fi

FB=$(v4l2-ctl -d "$DEV" --get-fmt-video 2>/dev/null | awk '/Size Image/{print $4}')
[ -n "$FB" ] && [ "$FB" != 0 ] || { echo "cannot read the frame size from $DEV"; exit 2; }

mean_of_last() { # file
	python3 - "$1" "$FB" "$H" <<-'PY'
	import sys, numpy as np
	path, fb, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
	d = np.fromfile(path, dtype=np.uint16)
	n = len(d) // (fb // 2)
	if n == 0:
	    print("-1 -1 -1")
	    raise SystemExit
	f = d[(n - 1) * fb // 2:n * fb // 2].reshape(h, -1).astype(np.float32)
	print("%.1f %.1f %d" % (f.mean(), f.std(), f.max()))
	PY
}

# Streams, changes a control a moment in, and returns the last frame.
probe() { # "ctrl=val,..." frames
	rm -f "$TMP/p.raw"
	timeout 60 v4l2-ctl -d "$DEV" --stream-mmap --stream-count="$2" \
		--stream-to="$TMP/p.raw" >/dev/null 2>&1 &
	local pid=$!
	sleep 1.2
	v4l2-ctl -d "$DEV" --set-ctrl "$1" >/dev/null 2>&1
	wait $pid 2>/dev/null
	mean_of_last "$TMP/p.raw"
}

echo "== frame rate"
# One stream throughout: v4l2-ctl prints '<' per frame, so counting those
# characters over a fixed window gives the rate the sensor really delivers.
rm -f "$TMP/f.txt"; : > "$TMP/f.txt"
v4l2-ctl -d "$DEV" --set-ctrl frame_rate=30000000 >/dev/null 2>&1
stdbuf -o0 timeout 60 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=1200 \
	> "$TMP/f.txt" 2>&1 &
stream_pid=$!
sleep 3
for want in 30 15 5; do
	v4l2-ctl -d "$DEV" --set-ctrl frame_rate=$((want * 1000000)) >/dev/null 2>&1
	sleep 1
	a=$(tr -cd '<' < "$TMP/f.txt" | wc -c)
	sleep 5
	b=$(tr -cd '<' < "$TMP/f.txt" | wc -c)
	got=$(python3 -c "print('%.2f' % (($b - $a) / 5.0))")
	if python3 -c "import sys; sys.exit(0 if abs($got - $want) <= 0.15 * $want else 1)"; then
		echo "PASS frame_rate $want fps: measured $got"
	else
		echo "FAIL frame_rate $want fps: measured $got"
		fail=1
	fi
done
kill $stream_pid 2>/dev/null; wait $stream_pid 2>/dev/null
v4l2-ctl -d "$DEV" --set-ctrl frame_rate=30000000 >/dev/null 2>&1

# Exposure and gain need light. Their effect is judged as a ratio against
# the sensor black level, so a covered lens is reported as inconclusive
# rather than as a driver failure.
echo "== exposure"
read -r dark _ _ <<<"$(probe "gain=16,exposure=93" 40)"
read -r lo _ _ <<<"$(probe "gain=16,exposure=2000" 40)"
read -r hi hi_std hi_max <<<"$(probe "gain=16,exposure=32000" 40)"
if python3 -c "import sys; sys.exit(0 if $hi - $dark < 3 else 1)"; then
	echo "SKIP exposure: the scene is too dark to tell (mean $dark to $hi)"
else
	rise=$(python3 -c "print('%.2f' % (($hi - $dark) / max($lo - $dark, 0.1)))")
	# 2000 to 32000 us is 16x more light, so the signal above black must
	# grow several times over unless it clips first.
	if python3 -c "import sys; sys.exit(0 if $rise >= 3.0 else 1)"; then
		echo "PASS exposure: signal above black grew ${rise}x from 2 ms to 32 ms"
	else
		echo "FAIL exposure: signal above black grew only ${rise}x from 2 ms to 32 ms"
		fail=1
	fi
fi

echo "== gain"
read -r g1 _ _ <<<"$(probe "exposure=2000,gain=16" 40)"
read -r g2 _ _ <<<"$(probe "exposure=2000,gain=256" 40)"
if python3 -c "import sys; sys.exit(0 if $g2 - $dark < 3 else 1)"; then
	echo "SKIP gain: the scene is too dark to tell"
else
	rise=$(python3 -c "print('%.2f' % (($g2 - $dark) / max($g1 - $dark, 0.1)))")
	if python3 -c "import sys; sys.exit(0 if $rise >= 3.0 else 1)"; then
		echo "PASS gain: signal above black grew ${rise}x from 1x to 16x"
	else
		echo "FAIL gain: signal above black grew only ${rise}x from 1x to 16x"
		fail=1
	fi
fi

# The sensor's own bar pattern is generated after the pixel array, so it
# arrives whatever the lens sees. That makes it the one content check
# that works on a dark bench, and it exercises the whole CSI and VI path.
DBG=$(ls -d /sys/kernel/debug/ov5647-* 2>/dev/null | head -1)
echo "== test pattern"
if [ -z "$DBG" ]; then
	echo "SKIP test pattern: no debugfs directory (CONFIG_DEBUG_FS off?)"
else
	rm -f "$TMP/t.raw"
	timeout 60 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=40 \
		--stream-to="$TMP/t.raw" >/dev/null 2>&1 &
	pid=$!
	sleep 1.2
	echo "0x503d 0x80" > "$DBG/reg" 2>/dev/null
	wait $pid 2>/dev/null
	bars=$(python3 - "$TMP/t.raw" "$FB" "$H" "$W" <<-'PY'
	import sys, numpy as np
	path, fb, h, w = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
	d = np.fromfile(path, dtype=np.uint16)
	n = len(d) // (fb // 2)
	if n == 0:
	    print(0)
	    raise SystemExit
	f = d[(n - 1) * fb // 2:n * fb // 2].reshape(h, fb // h // 2)[:, :w]
	row = f[h // 2].astype(int)
	# eight equal bars, each a flat level: count how many distinct ones
	mids = [int(np.median(row[int((i + 0.5) * w / 8) - 20:int((i + 0.5) * w / 8) + 20]))
	        for i in range(8)]
	print(len(set(mids)))
	PY
	)
	# Turn the pattern back off. This needs its own stream: the register
	# interface refuses writes once the sensor is powered down, so it
	# cannot be done after the capture above has ended.
	timeout 30 v4l2-ctl -d "$DEV" --stream-mmap --stream-count=20 \
		--stream-to=/dev/null >/dev/null 2>&1 &
	pid=$!
	sleep 1.2
	echo "0x503d 0x00" > "$DBG/reg" 2>/dev/null
	wait $pid 2>/dev/null

	if [ "$bars" -ge 3 ]; then
		echo "PASS test pattern: $bars distinct bar levels across the frame"
	else
		echo "FAIL test pattern: only $bars distinct levels, pattern did not reach the frame"
		fail=1
	fi
fi

[ "$fail" = 0 ] && echo "ALL CONTROL CHECKS PASSED" || echo "SOME CONTROL CHECKS FAILED"
exit $fail
