# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
# Out-of-tree build of the ov5647 tegracam module.
# Run `make` on any supported Jetson; the header layout is auto-detected:
#
#   L4T R32.x (Nano,   kernel 4.9):  /usr/src/linux-headers-*/kernel-4.9  + nvidia/
#   L4T R35.x (Xavier, kernel 5.10): /usr/src/linux-headers-*/kernel-5.10 + nvidia/
#   JetPack 7 (L4T r39, kernel 6.8): /lib/modules/$(uname -r)/build
#       + shipped OOT headers /usr/src/nvidia/nvidia-public (tegracam symbols
#         come from its Module.symvers; compat/ supplies nvidia/conftest.h)
#
# Headers come from nvidia-l4t-kernel-headers; JetPack 7 additionally
# needs nvidia-l4t-kernel-oot-headers for /usr/src/nvidia/nvidia-public.

KVER ?= $(shell uname -r)

NVPUB := /usr/src/nvidia/nvidia-public

ifneq ($(wildcard $(NVPUB)/include/media/tegracam_core.h),)
  # JetPack 7 style: OOT nvidia-public headers, kernel via the build symlink
  KDIR ?= $(firstword $(wildcard /lib/modules/$(KVER)/build))
  KDIR_ERR := no kernel build tree at /lib/modules/$(KVER)/build: install the \
kernel headers, or pass KDIR=
  NVINC := $(NVPUB)/include
  EXTRA_SYMBOLS := $(NVPUB)/Module.symvers
  COMPAT_INC := $(src)/compat
else
  # R32/R35 style: everything under one linux-headers dir
  HDRS ?= $(firstword $(wildcard /usr/src/linux-headers-$(KVER)-ubuntu*_aarch64))
  KDIR ?= $(firstword $(wildcard $(HDRS)/kernel-*))
  # reported by the build recipe, not here, so `clean` works without headers.
  # HDRS, not KDIR: the tegracam include path is derived from it too.
  KDIR_ERR := no kernel headers for $(KVER): install nvidia-l4t-kernel-headers, or pass \
HDRS=/usr/src/linux-headers-...
  NVINC := $(HDRS)/nvidia/include
  EXTRA_SYMBOLS :=
  COMPAT_INC :=
endif

obj-m := ov5647.o

ccflags-y += -I$(NVINC)
ifneq ($(COMPAT_INC),)
ccflags-y += -I$(COMPAT_INC)
endif

all:
	@[ -n "$(KDIR)" ] || { echo "$(KDIR_ERR)" >&2; exit 1; }
	$(MAKE) -C $(KDIR) M=$(CURDIR) KBUILD_EXTRA_SYMBOLS="$(EXTRA_SYMBOLS)" modules

clean:
	rm -f ov5647.ko ov5647.o ov5647.mod ov5647.mod.c ov5647.mod.o \
		.ov5647.* Module.symvers modules.order
	rm -rf .tmp_versions

# run as root; updates/ is the out-of-tree module location and takes
# depmod precedence over any in-tree module of the same name
install: all
	mkdir -p /lib/modules/$(KVER)/updates
	cp ov5647.ko /lib/modules/$(KVER)/updates/
	depmod -a $(KVER)
