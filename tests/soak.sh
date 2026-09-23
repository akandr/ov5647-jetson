#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Long-run stability check for the OV5647 driver. Run ON the board.
#
#   sudo tests/soak.sh [minutes]      # default 60
#
# One uninterrupted ISP capture, watching for leaks, thermal throttling
# and frame rate drift, none of which a short capture shows.
#
# The scene does not matter; a dark one exercises the same path.
set -uo pipefail

MINUTES=${1:-60}
MODE=${MODE:-1}
W=${W:-1920}
H=${H:-1080}
FPS=${FPS:-30}
DEV=${DEV:-/dev/video0}

command -v gst-launch-1.0 >/dev/null || { echo "need gstreamer1.0-tools"; exit 2; }
[ -e "$DEV" ] || { echo "no $DEV: is the driver loaded and the overlay applied?"; exit 2; }
[ "$(id -u)" = 0 ] || echo "note: not root, dmesg and rebinding may be unavailable"

FRAMES=$((MINUTES * 60 * FPS))
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A stale capture holds the sensor and fails the run in the first second.
pkill -9 v4l2-ctl 2>/dev/null
systemctl restart nvargus-daemon 2>/dev/null
sleep 3

zones() { # name=temp pairs, in millidegrees as the kernel reports them
	local z
	for z in /sys/devices/virtual/thermal/thermal_zone*; do
		[ -r "$z/type" ] && printf '%s=%s ' "$(cat "$z/type")" "$(cat "$z/temp")"
	done
}
rss_of() { # process name -> total RSS in kB
	local total=0 p
	for p in $(pgrep -f "$1" 2>/dev/null); do
		total=$((total + $(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)))
	done
	echo "$total"
}

echo "== soak: ${MINUTES} min, mode $MODE, ${W}x${H} at ${FPS} fps, $FRAMES frames"
echo "   start $(date '+%H:%M:%S'), temps: $(zones)"

dmesg_mark=$(dmesg 2>/dev/null | wc -l)
mem_start=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)

# -v with a talking fakesink logs one line per buffer with its PTS.
# Frame rate comes from those timestamps, so Argus startup (tens of
# seconds) is not counted as the capture falling behind.
start=$(date +%s)
gst-launch-1.0 -v nvarguscamerasrc sensor-id=0 sensor-mode=$MODE num-buffers=$FRAMES \
	! "video/x-raw(memory:NVMM),width=$W,height=$H,framerate=$FPS/1" \
	! fakesink sync=false silent=false > "$TMP/gst.log" 2>&1 &
gst_pid=$!

# Sample while it runs: a run that holds its frame count while climbing
# 15 degrees has not passed. The first sample is also the memory
# baseline, since the daemon claims its working set at stream start.
: > "$TMP/samples"
echo "== samples (every 30 s)"
while kill -0 $gst_pid 2>/dev/null; do
	sleep 30
	kill -0 $gst_pid 2>/dev/null || break
	printf '%s elapsed=%s mem_avail=%s argus_rss=%s gst_rss=%s %s\n' \
		"$(date '+%H:%M:%S')" "$(( $(date +%s) - start ))" \
		"$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" \
		"$(rss_of nvargus-daemon)" "$(rss_of 'gst-launch')" "$(zones)" \
		| tee -a "$TMP/samples"
done
wait $gst_pid 2>/dev/null
gst_rc=$?
elapsed=$(( $(date +%s) - start ))

mem_end=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)

fail=0
echo
echo "== results"
if [ "$gst_rc" != 0 ]; then
	echo "FAIL pipeline exited $gst_rc before delivering $FRAMES frames"
	tail -5 "$TMP/gst.log"
	fail=1
else
	echo "PASS pipeline delivered all $FRAMES frames"
fi

# Pace, from the buffer timestamps rather than the clock: how many frames
# arrived and how much time passed between the first and the last.
read -r got rate <<<"$(python3 - "$TMP/gst.log" <<-'PY'
	import re, sys
	pts = [int(h) * 3600 + int(m) * 60 + float(s)
	       for h, m, s in re.findall(r'pts: (\d+):(\d+):(\d+\.\d+)', open(sys.argv[1]).read())]
	span = pts[-1] - pts[0] if len(pts) > 1 else 0
	print(len(pts), "%.3f" % ((len(pts) - 1) / span) if span > 0 else "0")
	PY
)"
if [ "${got:-0}" -lt 2 ]; then
	echo "FAIL pace: no timestamped buffers in the log"
	fail=1
elif python3 -c "import sys; sys.exit(0 if abs($rate - $FPS) <= 0.05 * $FPS else 1)"; then
	echo "PASS pace: $got frames at $rate fps over ${elapsed}s wall clock"
else
	echo "FAIL pace: $got frames at $rate fps, wanted $FPS"
	fail=1
fi

# The daemon holds the ISP state, so its size is the one worth watching.
# Samples come from while the stream was up; reading after teardown
# measures the teardown.
#
# The verdict is on the final third: a daemon that claims its working set
# and settles is fine, one still growing after an hour is not.
read -r argus_start argus_end argus_tail <<<"$(awk '
	{for (i = 1; i <= NF; i++) if ($i ~ /^argus_rss=/) v[++n] = substr($i, 11)}
	END {
		if (n == 0) { print "0 0 0"; exit }
		t = int(n * 2 / 3); if (t < 1) t = 1
		print v[1], v[n], v[n] - v[t]
	}' "$TMP/samples")"
drift=$((argus_end - argus_start))
if [ "${argus_tail:-0}" -lt 4096 ]; then
	echo "PASS nvargus-daemon RSS ${argus_start} -> ${argus_end} kB" \
	     "(${drift} kB in total, ${argus_tail} kB over the final third)"
else
	echo "FAIL nvargus-daemon RSS still climbing at the end:" \
	     "${argus_tail} kB over the final third alone (${drift} kB in total)"
	fail=1
fi
echo "     MemAvailable ${mem_start} -> ${mem_end} kB"

if [ -s "$TMP/samples" ]; then
	echo
	echo "== temperature, per zone, over the run"
	python3 - "$TMP/samples" <<-'PY' 2>/dev/null || echo "   (needs python3)"
	import sys, re, collections
	zones = collections.defaultdict(list)
	for line in open(sys.argv[1]):
	    for name, val in re.findall(r'([A-Za-z0-9_-]+)=(\d+)(?=\s|$)', line):
	        if name in ('elapsed', 'mem_avail', 'argus_rss', 'gst_rss'):
	            continue
	        zones[name].append(int(val) / 1000.0)
	for name, vals in zones.items():
	    print("   %-16s %.1f -> %.1f C (min %.1f, max %.1f)"
	          % (name, vals[0], vals[-1], min(vals), max(vals)))
	PY
fi

# Scoped to the capture path: an hour of any board's log holds an
# unrelated "error", and failing on a wifi message helps nobody.
new_errors=$(dmesg 2>/dev/null | tail -n +$((dmesg_mark + 1)) |
	grep -iE 'tegra-vi|tegra_vi|vi[0-9]*:|nvcsi|argus|vb2|videobuf|ov5647|mc-err|syncpoint' |
	head -20)
if [ -n "$new_errors" ]; then
	echo "FAIL kernel logged this during the run:"
	echo "$new_errors" | sed 's/^/     /'
	fail=1
else
	echo "PASS nothing new in dmesg"
fi

# An Argus run leaves the raw path dead until the driver is rebound.
drv=/sys/bus/i2c/drivers/ov5647
for path in "$drv"/[0-9]*-[0-9a-f]*; do
	[ -e "$path" ] || continue
	dev=${path##*/}
	if echo "$dev" > "$drv/unbind" 2>/dev/null; then
		sleep 2; echo "$dev" > "$drv/bind" 2>/dev/null; sleep 3
		echo "     raw path rebound ($dev)"
	fi
	break
done

[ "$fail" = 0 ] && echo "SOAK PASSED" || echo "SOAK FAILED"
exit $fail
