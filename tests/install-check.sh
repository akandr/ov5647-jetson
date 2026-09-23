#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Did the install take? Run ON the board, after installing and rebooting.
#
#   sudo tests/install-check.sh
#
# install.sh writes a module, merges a device tree and repoints the boot
# entry. Checking each separately makes a failure name itself, where a
# capture attempt only says that something is wrong.
#
# A board with no camera reports that, not failure: everything up to the
# ribbon is still verifiable.
set -uo pipefail

fail=0
KVER=$(uname -r)

# grep -q under pipefail reports SIGPIPE from the producer as the
# pipeline status, and only when the producer is still writing. It
# passed on the Nano and lied on the Orin. grep -c reads to the end.
echo "== module"
if [ "$(lsmod | grep -c '^ov5647')" -eq 0 ]; then
	echo "FAIL ov5647 is not loaded; try 'sudo modprobe ov5647' and check dmesg"
	fail=1
else
	plik=$(modinfo -n ov5647 2>/dev/null)
	case $plik in
	*/updates/*)
		echo "PASS loaded from $plik" ;;
	"")
		echo "WARN loaded, but modinfo cannot say from where" ;;
	*)
		echo "FAIL loaded from $plik, which is not the out-of-tree copy"
		echo "     install.sh puts it in /lib/modules/$KVER/updates/"
		fail=1 ;;
	esac
fi

# extlinux.conf says what was asked for, /proc/device-tree what booted.
echo "== device tree"
wezel=""
while IFS= read -r c; do
	if [ "$(tr -d '\0' < "$c" 2>/dev/null | grep -cx 'nvidia,ov5647')" -gt 0 ]; then
		wezel=$(dirname "$c"); break
	fi
	# /proc/device-tree is a symlink into /sys; find needs -L and the
	# trailing slash to walk it.
done < <(find -L /proc/device-tree/ -name compatible 2>/dev/null)
if [ -z "$wezel" ]; then
	echo "FAIL no ov5647 node in the live device tree: the board did not boot"
	echo "     the merged DTB. Check the FDT line in /boot/extlinux/extlinux.conf"
	fail=1
else
	echo "PASS sensor node in the live tree: ${wezel#/proc/device-tree}"
	tryby=$(find -L "$wezel" -maxdepth 2 -type d -name 'mode[0-9]*' 2>/dev/null | wc -l)
	if [ "$tryby" -gt 0 ]; then
		echo "PASS the tree offers $tryby modes"
	else
		echo "FAIL the sensor node carries no modeX nodes"
		fail=1
	fi
	for p in horizontal-mirror vertical-flip; do
		[ -e "$wezel/$p" ] && echo "     note: $p is set in the tree"
	done
fi

# The driver reads the chip ID before registering, so a bound device
# means the sensor answered on i2c.
echo "== sensor"
drv=/sys/bus/i2c/drivers/ov5647
zwiazany=""
for path in "$drv"/[0-9]*-[0-9a-f]*; do
	[ -e "$path" ] && { zwiazany=${path##*/}; break; }
done
if [ -n "$zwiazany" ]; then
	echo "PASS sensor answered and the driver bound it as $zwiazany"
elif [ "$(dmesg 2>/dev/null |
	grep -c 'ov5647.*error during i2c read probe')" -gt 0 ]; then
	echo "SKIP no camera on the connector: the probe stopped at the chip-ID"
	echo "     read, which is where it stops with nothing on the ribbon."
	echo "     Everything above this line is installed correctly."
elif [ ! -d "$drv" ]; then
	echo "FAIL the driver registered no i2c driver at all"
	fail=1
else
	echo "FAIL the driver is loaded but bound nothing, and the log does not"
	echo "     name a failed chip-ID read. Look at dmesg | grep ov5647"
	fail=1
fi

echo "== capture device"
if [ -n "$zwiazany" ] && [ -e /dev/video0 ]; then
	# A missing v4l2-ctl would otherwise report zero modes.
	if ! command -v v4l2-ctl >/dev/null; then
		echo "PASS /dev/video0 present"
		echo "SKIP mode list: v4l2-ctl not installed (apt install v4l-utils)"
	else
		n=$(v4l2-ctl -d /dev/video0 --list-formats-ext 2>/dev/null |
			grep -c 'Size: Discrete')
		echo "PASS /dev/video0 present, advertising $n modes"
		[ "$n" -gt 0 ] || { echo "FAIL it advertises no modes"; fail=1; }
	fi
elif [ -n "$zwiazany" ]; then
	echo "FAIL the sensor is bound but /dev/video0 does not exist"
	fail=1
else
	echo "SKIP no capture device without a camera, as expected"
fi

echo
if [ "$fail" = 0 ]; then
	if [ -n "$zwiazany" ]; then
		echo "INSTALL OK: camera present, run tests/capture-check.sh next"
	else
		echo "INSTALL OK as far as it can go without a camera on the connector"
	fi
else
	echo "INSTALL INCOMPLETE"
fi
exit $fail
