/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
 *
 * Minimal stand-in for NVIDIA's generated <nvidia/conftest.h>.
 *
 * On JetPack 7 the shipped nvidia-public headers
 * (/usr/src/nvidia/nvidia-public/include) reference NV_* feature-test
 * macros that NVIDIA's out-of-tree module build generates with a conftest
 * script. The generated header itself is not shipped on the device, so
 * this file provides the macros the camera headers actually use: the two
 * that track a kernel API change are keyed off the version, the other two
 * are set outright for L4T.
 *
 * CAUTION: NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT gates a field inside
 * struct camera_common_data. Getting it wrong breaks the struct layout
 * against the precompiled tegra-camera module. Each value below was
 * checked against L4T r39.2 (kernel 6.8.12-tegra, Ubuntu 24.04):
 *   - tegra_pmc_io_pad_power_enable is exported (/proc/kallsyms)
 *   - the kernel is an L4T one (/etc/nv_tegra_release)
 *   - struct v4l2_async_connection exists (include/media/v4l2-async.h)
 *   - struct tegra_ivc carries an iosys_map (include/soc/tegra/ivc.h)
 *
 * Only the JetPack 7 build path puts this directory on the include path;
 * older L4T headers never include <nvidia/conftest.h>.
 */
#ifndef __OV5647_NVIDIA_CONFTEST_COMPAT_H__
#define __OV5647_NVIDIA_CONFTEST_COMPAT_H__

#include <linux/version.h>

/* NVIDIA builds the L4T OOT tree with system_type=l4t */
#define NV_IS_L4T 1

/* tegra kernels export tegra_pmc_io_pad_power_enable() */
#define NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT

/* struct v4l2_async_connection replaced v4l2_async_subdev in v6.6 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
#define NV_V4L2_ASYNC_CONNECTION_STRUCT_PRESENT
#endif

/* struct tegra_ivc switched to iosys_map buffers in v6.2 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 2, 0)
#define NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP
#endif

#endif /* __OV5647_NVIDIA_CONFTEST_COMPAT_H__ */
