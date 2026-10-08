#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
#
# Capture a ColorChecker in raw at several exposures, for fit.py. Run on
# the board:
#
#   tools/isp/capture-raw.sh OUTDIR [DEV] [EXPOSURE_US ...]
#
# Full resolution (sensor_mode 0), gain 1x. Each exposure gives
# OUTDIR/e<us>.bin with two frames. Pick the longest exposure whose
# white patch stays below about 85% of full scale; the script prints the
# 99.9th percentile of each capture to help.
#
# Argus leaves the VI control bypass_mode at 1, and the raw path delivers
# nothing until it is back at 0. The script sets it first. If the capture
# still comes back empty, run with REBIND=1 as root to rebind the sensor
# driver as well (see the README).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 OUTDIR [DEV] [EXPOSURE_US ...]" >&2; exit 2; }
out=$1; shift
dev=/dev/video0
[ $# -ge 1 ] && { dev=$1; shift; }
exps=${*:-5000 10000 20000 40000}
mkdir -p "$out"

if [ "${REBIND:-0}" = 1 ]; then
	systemctl stop nvargus-daemon 2>/dev/null || true
	for d in /sys/bus/i2c/drivers/ov5647/*-0036; do
		n=$(basename "$d")
		echo "$n" > /sys/bus/i2c/drivers/ov5647/unbind
		echo "$n" > /sys/bus/i2c/drivers/ov5647/bind
	done
	sleep 3
fi

v4l2-ctl -d "$dev" --set-ctrl bypass_mode=0,override_enable=0 || true
v4l2-ctl -d "$dev" --set-ctrl sensor_mode=0
v4l2-ctl -d "$dev" --set-fmt-video=width=2592,height=1944,pixelformat=BG10
for e in $exps; do
	v4l2-ctl -d "$dev" --set-ctrl gain=16,exposure="$e"
	tmp="$out/.e$e"
	timeout 30 v4l2-ctl -d "$dev" --stream-mmap --stream-count=4 \
		--stream-to="$tmp" >/dev/null 2>&1 || true
	# The last two frames, after the first ones have settled.
	tail -c $((2592 * 1944 * 2 * 2)) "$tmp" > "$out/e$e.bin"
	rm -f "$tmp"
	python3 - "$out/e$e.bin" "$e" <<-'PY'
	import sys, numpy as np
	a = np.fromfile(sys.argv[1], np.uint16).astype(float)
	if a.size == 0:
	    sys.exit(f"exposure {sys.argv[2]} us: no frames")
	a = a / 64 if a.max() > 1023 else a
	print(f"exposure {sys.argv[2]:>6} us: 99.9th percentile {np.percentile(a, 99.9):5.0f} of 1023")
	PY
done
