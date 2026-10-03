#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
#
# List the keys of the generic ISP tuning that L4T stores as text inside
# libnvscf.so, with their default values. Run on the board:
#
#   tools/isp/dump-defaults.sh > defaults.txt
#   grep '^awb\.' defaults.txt
set -eu

LIB=${1:-/usr/lib/aarch64-linux-gnu/tegra/libnvscf.so}
[ -r "$LIB" ] || { echo "no $LIB: is this an L4T board with Argus?" >&2; exit 1; }

strings -n 6 "$LIB" |
	grep -E '^[A-Za-z0-9]+\.[]A-Za-z0-9_.[]+ *=' |
	sort -u
