#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# OV5647 (Pi Camera v1) driver installer for NVIDIA Jetson. Run ON the board.
#
#   git clone <this repo> && cd ov5647-jetson && sudo ./install.sh
#   sudo ./install.sh --uninstall     # put the board back as it was
#
# Supported boards / L4T lines:
#   Jetson Nano 2GB  (P3448-0003 + P3542)      L4T R32.7.x  (kernel 4.9)
#   Jetson Xavier NX devkit (P3668 + P3509)    L4T R35.x    (kernel 5.10)
#   Jetson Orin Nano/NX devkit (P3767 + P3768) JetPack 7 / L4T r39 (kernel 6.8)
#
# What it does, in this order so nothing the board boots from changes
# until the last step:
#   1. installs what it needs to build with apt: device-tree-compiler and
#      the L4T kernel headers, plus the OOT headers on JetPack 7
#   2. builds ov5647.ko against the installed kernel headers
#   3. compiles the board's DT overlay and merges it onto the DTB the board
#      actually boots (stock DTB is NOT touched)
#   4. installs the module into /lib/modules, runs depmod, and points the
#      extlinux.conf FDT line at the merged copy
# To revert: run it again with --uninstall, which restores the
# extlinux.conf backup this script makes and removes the module and the
# files it wrote under /boot.
#
# The camera goes in the CAM0 connector (Orin devkits need a 15->22 pin
# adapter ribbon). Reboot after installing.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo" >&2; exit 1; }

UNINSTALL=""
case "${1:-}" in
"")		;;
--uninstall)	UNINSTALL=1 ;;
*)		echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

echo "== detect board =="
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
compat=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null || true)
echo "board: $model"

# If the boot entry already names a DTB, that is the one in use; prefer it
# over any per-board guess below, skipping our own output on a re-install.
EXT=/boot/extlinux/extlinux.conf
OV=/boot/kernel-ov5647-merged.dtb
PRISTINE=/boot/kernel-ov5647-base.dtb
BASE_SRC=/boot/kernel-ov5647-base.src
[ -r "$EXT" ] || { echo "ERROR: $EXT not found; this installer selects the DTB through it" >&2; exit 1; }
# The entry that boots is the one DEFAULT names; with no DEFAULT, extlinux
# takes the first LABEL. Scope both the read below and the write later on to
# that one entry, so a second LABEL carrying its own FDT is left alone.
LABEL=$(sed -n 's/^[[:space:]]*DEFAULT[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$EXT" | head -1)
entry_awk='
	function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
	function pick(line,   lbl) {
		lbl = line; sub(/^[ \t]*LABEL[ \t]+/, "", lbl); sub(/[ \t].*$/, "", lbl)
		if (want != "") return (lbl == want)
		if (seen) return 0
		seen = 1; return 1
	}'
BOOT_DTB=$(awk -v want="$LABEL" -v ov="$OV" "$entry_awk"'
	{
		if ($0 ~ /^[ \t]*LABEL[ \t]/) inblk = pick($0)
		if (inblk && $0 ~ /^[ \t]*FDT[ \t]/) {
			p = $0; sub(/^[ \t]*FDT[ \t]+/, "", p); sub(/[ \t]+$/, "", p)
			if (p != ov) { print p; exit }
		}
	}' "$EXT")

case "$compat" in
	*p3448-0003*)
		BOARD=nano
		DTS=dt/nano/tegra210-p3448-0003-ov5647-overlay.dts
		BASE=${BOOT_DTB:-/boot/tegra210-p3448-0003-p3542-0000.dtb}
		grep -q "R32" /etc/nv_tegra_release || { echo "ERROR: L4T R32.x expected on Nano" >&2; exit 1; }
		;;
	*p3448*)
		echo "ERROR: Jetson Nano 4GB is not supported yet (overlay symbols unverified)" >&2
		exit 1
		;;
	*p3668*)
		BOARD=xavier
		DTS=dt/xavier/tegra194-p3668-ov5647-overlay.dts
		# One DTB per module SKU ships; only the one extlinux names is
		# in use. Without an FDT line, fall back on the SKU the board
		# reports rather than on whichever file sorts first.
		sku=$(printf '%s' "$compat" | grep -o 'p3668-[0-9]*' | head -1 || true)
		BASE=${BOOT_DTB:-$(ls /boot/dtb/kernel_tegra194-"${sku:-p3668}"-*.dtb 2>/dev/null | head -1 || true)}
		grep -q "R35" /etc/nv_tegra_release || { echo "ERROR: L4T R35.x expected on Xavier NX" >&2; exit 1; }
		;;
	*p3767*)
		BOARD=orin
		DTS=dt/orin/tegra234-p3767-ov5647-overlay.dts
		# JetPack 7 boots a DTB handed over by UEFI, which extlinux
		# does not name before this installer adds a line, so the live
		# tree is the only copy of it the running system has. It
		# carries the firmware's runtime fixups (/chosen, memory map);
		# the kernel re-applies its own on the next boot.
		BASE=${BOOT_DTB:-/sys/firmware/fdt}
		grep -q "R39" /etc/nv_tegra_release || { echo "ERROR: JetPack 7 (L4T r39) expected on Orin" >&2; exit 1; }
		;;
	*)
		echo "ERROR: unsupported board (compatible: $compat)" >&2; exit 1 ;;
esac
echo "board type: $BOARD"

KVER=$(uname -r)

# Undo exactly what a successful install wrote, in the reverse order: the boot
# entry first, so a half-finished removal still leaves the board booting the
# stock tree rather than a merged one whose files are gone.
if [ -n "$UNINSTALL" ]; then
	echo "== uninstall =="
	if [ -e "$EXT.orig" ]; then
		cp "$EXT.orig" "$EXT"
		echo "restored $EXT from the backup taken at install"
	else
		echo "no $EXT.orig backup: leaving $EXT alone"
		echo "  check its FDT line by hand if it names $OV"
	fi
	rm -f "/lib/modules/$KVER/updates/ov5647.ko" "$OV" "$PRISTINE" "$BASE_SRC"
	depmod -a "$KVER"
	rmmod ov5647 2>/dev/null || true
	echo "removed the module and the files under /boot"
	echo
	echo "Uninstalled. Reboot to go back to the stock device tree."
	exit 0
fi

APT_UPDATED=""
apt_install() { # refresh the lists once, then install
	[ -n "$APT_UPDATED" ] || { apt-get update || true; APT_UPDATED=1; }
	apt-get install -y "$@"
}
command -v dtc >/dev/null || apt_install device-tree-compiler
command -v fdtoverlay >/dev/null || { echo "ERROR: fdtoverlay missing (device-tree-compiler too old)" >&2; exit 1; }
if [ ! -e "/lib/modules/$KVER/build" ] && ! ls -d /usr/src/linux-headers-"$KVER"-ubuntu*_aarch64 >/dev/null 2>&1; then
	apt_install nvidia-l4t-kernel-headers
fi
if [ "$BOARD" = orin ] && [ ! -d /usr/src/nvidia/nvidia-public ]; then
	# tegracam headers and Module.symvers for out-of-tree builds on JetPack 7
	apt_install nvidia-l4t-kernel-oot-headers
	[ -d /usr/src/nvidia/nvidia-public ] || { echo "ERROR: /usr/src/nvidia/nvidia-public missing (nvidia-l4t-kernel-oot-headers)" >&2; exit 1; }
fi

echo "== build kernel module =="
make -C driver

echo "== build & install device tree =="

# A re-install sees only our own merged DTB in extlinux, so the board-specific
# guess above would have to be right a second time. Prefer the path the first
# install recorded: it still tracks L4T upgrades of that file, and it cannot
# drift to a different DTB than the one this board was set up with.
if [ -r "$BASE_SRC" ]; then
	recorded=$(cat "$BASE_SRC")
	[ -e "$recorded" ] && BASE=$recorded
fi
# Re-installs must never merge on top of an already merged tree. Where the
# stock DTB is a file we can name, take it fresh every time so an L4T upgrade
# is picked up, and keep a snapshot for the case below. On JetPack 7 the base
# is the live tree, which after the first install is the merged one, so there
# the snapshot is the only untouched copy the system still has.
if [ -n "$BASE" ] && [ -e "$BASE" ] && [ "$BASE" != /sys/firmware/fdt ]; then
	cp "$BASE" "$PRISTINE"
	printf '%s\n' "$BASE" > "$BASE_SRC"
elif [ -e "$PRISTINE" ]; then
	echo "using the base DTB snapshot from the first install"
	BASE=$PRISTINE
else
	[ -n "$BASE" ] && [ -e "$BASE" ] || { echo "ERROR: base DTB not found" >&2; exit 1; }
	cp "$BASE" "$PRISTINE"
fi
DTBO=$(mktemp --suffix=.dtbo)
trap 'rm -f "$DTBO"' EXIT
# dtc prints cosmetic graph warnings for overlay fragments; they are expected
dtc -@ -I dts -O dtb -o "$DTBO" "$DTS"
fdtoverlay -i "$BASE" -o "$OV" "$DTBO"

echo "== install kernel module =="
make -C driver install

echo "== select the merged device tree =="
[ -f "$EXT.orig" ] || cp "$EXT" "$EXT.orig"
# Edit the entry DEFAULT names, not merely the first one: extlinux.conf may
# carry several LABEL blocks and the bootable one is whichever DEFAULT picks.
# Drop every FDT line in that entry and write exactly one, so a config left
# with duplicates by an earlier run converges to a single line.
awk -v ov="$OV" -v want="$LABEL" "$entry_awk"'
	function flush(   k) {
		if (!n) return
		for (k = 1; k <= n; k++) {
			print buf[k]
			if (k == at) { print pad "FDT " ov; done = 1 }
		}
		n = 0; at = 0
	}
	{
		line = $0
		if (line ~ /^[ \t]*LABEL[ \t]/) {
			flush()
			inblk = pick(line)
			if (!inblk) { print line; next }
			buf[++n] = line; next
		}
		if (!inblk) { print line; next }
		if (line ~ /^[ \t]*FDT[ \t]/) next
		buf[++n] = line
		if (line ~ /^[ \t]*INITRD[ \t]/) { at = n; pad = indent(line) }
		else if (!at && line ~ /^[ \t]*LINUX[ \t]/) { at = n; pad = indent(line) }
	}
	END { flush(); exit(done ? 0 : 1) }
' "$EXT" > "$EXT.new" || { rm -f "$EXT.new"; echo "ERROR: boot entry ${LABEL:-(first)} in $EXT has no LINUX or INITRD line to attach $OV to" >&2; exit 1; }
cat "$EXT.new" > "$EXT"
rm -f "$EXT.new"
grep -qF "$OV" "$EXT" || { echo "ERROR: could not add FDT entry to $EXT" >&2; exit 1; }

echo
echo "Installed ($BOARD). Reboot, then test with:"
echo "  gst-launch-1.0 nvarguscamerasrc ! 'video/x-raw(memory:NVMM),width=1920,height=1080' ! fakesink"
echo "To uninstall:"
echo "  sudo ./install.sh --uninstall && sudo reboot"
