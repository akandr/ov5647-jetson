#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Build the driver against one L4T line's kernel headers, without a Jetson.
#
#   .github/scripts/build-l4t.sh <nano|xavier|orin> [workdir]
#
# NVIDIA ships the headers as plain .deb files, so any aarch64 Linux box
# can do this: fetch, unpack, point the module Makefile at the result.
#
# aarch64 is required. The header packages carry NVIDIA's host tools
# (fixdep, modpost) as aarch64 binaries, which a cross build from x86
# would have to rebuild first.
#
# The module produced is a compile check. Releases are built on the
# boards, against the kernel that will load them.
set -uo pipefail

BOARD=${1:-}
WORK=${2:-$PWD/.l4t-build}

case $BOARD in
nano)	SOC=t210; DIST=r32.7; PKGS="nvidia-l4t-kernel-headers" ;;
xavier)	SOC=t194; DIST=r35.6; PKGS="nvidia-l4t-kernel-headers" ;;
# JetPack 7 keeps the tegracam headers in the out-of-tree package.
orin)	SOC=som;  DIST=r39.2; PKGS="nvidia-l4t-kernel-headers nvidia-l4t-kernel-oot-headers" ;;
*)	echo "usage: $0 <nano|xavier|orin> [workdir]" >&2; exit 2 ;;
esac

[ "$(uname -m)" = aarch64 ] || { echo "ERROR: this needs an aarch64 host, see the comment above" >&2; exit 2; }
for t in curl dpkg-deb dpkg make gcc; do
	command -v $t >/dev/null || { echo "ERROR: $t not installed" >&2; exit 2; }
done

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[ -f "$HERE/driver/Makefile" ] || { echo "ERROR: cannot find driver/ from $HERE" >&2; exit 2; }

BASE=https://repo.download.nvidia.com/jetson/$SOC
SYS=$WORK/sysroot-$BOARD
DEBS=$WORK/debs
BUILD=$WORK/build-$BOARD
mkdir -p "$SYS" "$DEBS"
rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "== $BOARD: L4T $DIST from $SOC"
INDEX=$DEBS/Packages-$SOC-$DIST
curl -fsSL --retry 3 -o "$INDEX" "$BASE/dists/$DIST/main/binary-arm64/Packages" \
	|| { echo "ERROR: cannot read the package index for $SOC $DIST" >&2; exit 1; }

# Pick the newest by dpkg ordering; a string compare gets 32.7.10 wrong.
field() { awk -v want="$1" -v key="$2" '
	/^Package: /{p = $2}
	$1 == key":" && p == want {print substr($0, length(key) + 3)}
	' "$INDEX"; }

for pkg in $PKGS; do
	best=""
	while read -r v; do
		[ -n "$v" ] || continue
		if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
	done < <(field "$pkg" Version)
	[ -n "$best" ] || { echo "ERROR: $pkg not in $SOC $DIST" >&2; exit 1; }

	# Filename and SHA256 must come from the same stanza.
	read -r fn sha < <(awk -v want="$pkg" -v ver="$best" '
		/^Package: /{p = $2; f = ""; s = ""; v = ""}
		/^Version: /{v = $2}
		/^Filename: /{f = $2}
		/^SHA256: /{s = $2}
		/^$/{if (p == want && v == ver && f != "") {print f, s; exit}}
		END{if (p == want && v == ver && f != "") print f, s}
		' "$INDEX")
	[ -n "$fn" ] || { echo "ERROR: no Filename for $pkg $best" >&2; exit 1; }

	deb=$DEBS/$(basename "$fn")
	echo "   $pkg $best"
	if [ ! -s "$deb" ]; then
		curl -fsSL --retry 3 -o "$deb" "$BASE/$fn" || { echo "ERROR: download failed: $fn" >&2; exit 1; }
	fi
	if [ -n "$sha" ]; then
		echo "$sha  $deb" | sha256sum -c --quiet || { echo "ERROR: checksum mismatch on $deb" >&2; exit 1; }
	fi
	dpkg-deb -x "$deb" "$SYS" || { echo "ERROR: cannot unpack $deb" >&2; exit 1; }
done

# The package names its own kernel, and vermagic has to match it.
HDRS=$(echo "$SYS"/usr/src/linux-headers-*_aarch64)
[ -d "$HDRS" ] || { echo "ERROR: no linux-headers directory in the package" >&2; exit 1; }
KVER=$(basename "$HDRS"); KVER=${KVER#linux-headers-}; KVER=${KVER%-ubuntu*}
echo "   kernel $KVER, gcc $(gcc -dumpversion)"

cp "$HERE/driver/ov5647.c" "$HERE/driver/ov5647_mode_tbls.h" "$HERE/driver/Makefile" "$BUILD/"
mkdir -p "$BUILD/compat/nvidia"
cp "$HERE/driver/compat/nvidia/conftest.h" "$BUILD/compat/nvidia/"

NVPUB=$SYS/usr/src/nvidia/nvidia-public
if [ -f "$NVPUB/include/media/tegracam_core.h" ]; then
	# The symlink holds an absolute path, so read it against the sysroot.
	KDIR=$SYS$(readlink "$SYS/lib/modules/$KVER/build" 2>/dev/null)
	[ -d "$KDIR" ] || { echo "ERROR: no kernel build tree for $KVER" >&2; exit 1; }
	set -- KVER="$KVER" KDIR="$KDIR" NVPUB="$NVPUB" KBUILD_EXTRA_WARN=1
else
	# R32/R35 keep both under one directory. NVPUB is pointed away so a
	# host with JetPack 7 headers installed still takes this branch.
	set -- KVER="$KVER" HDRS="$HDRS" NVPUB=/nonexistent KBUILD_EXTRA_WARN=1
fi

LOG=$BUILD/build.log
echo "== build"
make -C "$BUILD" "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "FAIL $BOARD: make exited $rc" >&2; exit 1; }
[ -f "$BUILD/ov5647.ko" ] || { echo "FAIL $BOARD: no module produced" >&2; exit 1; }

# modpost warns about a symbol the kernel no longer exports and builds
# the module anyway, so a green build would hide it.
if grep -qiE 'undefined|no symbol version' "$LOG"; then
	echo "FAIL $BOARD: unresolved symbols against the $DIST headers" >&2
	grep -iE 'undefined|no symbol version' "$LOG" >&2
	exit 1
fi

# Extra warnings fire freely in NVIDIA's headers, so only warnings
# naming a file from driver/ count.
ours=$(grep -i 'warning' "$LOG" | grep -E 'ov5647\.c|ov5647_mode_tbls\.h|conftest\.h' || true)
if [ -n "$ours" ]; then
	echo "FAIL $BOARD: the compiler warned about this driver's own sources" >&2
	printf '%s\n' "$ours" >&2
	exit 1
fi

got=$(modinfo -F vermagic "$BUILD/ov5647.ko")
case $got in
"$KVER "*)	echo "PASS $BOARD: built for $KVER (vermagic: $got)" ;;
*)		echo "FAIL $BOARD: vermagic '$got' does not name $KVER" >&2; exit 1 ;;
esac
