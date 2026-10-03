# Prior art: OV5647 on Jetson

Surveyed on 2026-07-29. The mainline row was rechecked on 2026-09-15
and tested on hardware on 2026-09-24.

| Project | State | Notes |
|---|---|---|
| [RidgeRun OV5647 driver](https://developer.ridgerun.com/wiki/index.php?title=OmniVision_OV5647_Linux_driver_for_Jetson_Nano) | working, commercial | L4T 32.1 / JetPack 4.2. 1920x1080@30 BGGR10 through the ISP. Shows that the sensor works with the T210 ISP. The sources are paid. |
| [jas-hacks Pi v1.3 camera driver](http://jas-hacks.blogspot.com/2019/08/jetson-nano-developing-pi-v13-camera.html) | alpha, 2019, unmaintained | Prebuilt kernel and DTB for L4T 32.2. Modes: 2592x1944@15, 1080p30, 1280x960@45, 720p60. A useful reference for modes and timings. |
| [Moore123/ov5647_jetson](https://github.com/Moore123/ov5647_jetson) | non-working | GPL-3. The README says "Not Working YET By Now". |
| [GiraffAI blog series](https://www.giraffai.com/nvidia-jetson-nano/developing-ov5647-sensor-linux-device-driver-for-jetson-nano-part1) | partial, educational | Raw V4L2 capture only (640x480 RG10 stills), no ISP integration. The series is unfinished. |
| Arducam OV5647 for Jetson | discontinued | Required the proprietary Jetvariety adapter. No native CSI driver. |
| Mainline kernel | T210 only, raw Bayer | `staging/media/tegra-video` covers Tegra20/30 and T210. T194 and T234 appear in neither its Makefile nor its Kconfig. Mainline has `drivers/media/i2c/ov5647.c`. The NVIDIA ISP userspace is not part of mainline, so the result is raw Bayer only. See below. |

## Mainline on Jetson

On the Nano mainline comes close. It has the VI and CSI driver in
staging, a `drivers/media/i2c/ov5647.c` with four modes and the usual
controls, and a device tree for the Jetson Nano 2GB
(`tegra210-p3541-0000.dts`) with VI, CSI and the camera I2C bus
enabled. The device tree has no sensor node and no port graph for the
camera.

Such a tree was written and tested on a Nano 2GB with a current
mainline kernel. With it and a few changes on the mainline side, all
four mainline modes capture raw. Full resolution needs a CMA pool
larger than the default 32 MiB (`cma=128M` on the command line). On
the Nano's Ubuntu 18.04 `haveged` must stay off. Under a new kernel it
grows to 1.8 GB within minutes, and full-resolution captures then run
out of memory.

Mainline offers no ISP on any Jetson. There is no hardware debayer, no
auto exposure or white balance, and no NVMM buffers for CUDA or the
encoders. For that reason this driver uses tegracam. On a Xavier NX or
an Orin mainline has no camera support at all.

## References used by this implementation

- Mainline `drivers/media/i2c/ov5647.c`: register sequences, per-mode
  HTS/VTS and PLL setup (GPL-2.0)
- L4T `nvidia/drivers/media/i2c/imx219.c`: tegracam driver model
- L4T IMX219 camera dtsi and overlays per board: device-tree graph model
- The 1280x720 mode comes from none of the above. It is the binned
  mode's register table with the readout window cut to 1464 array rows,
  short enough for 60 fps. The jas-hacks 720p60 mode confirms that the
  sensor reaches that rate. Its timings were not used.
- Module quirk: the Pi camera keeps the sensor unpowered until the
  connector's CAM0_PWDN line goes high. Checked on hardware: with the
  line high the chip answers at 0x36 and the ID registers 0x300A and
  0x300B read 0x56 and 0x47.
