# Prior art: OV5647 on Jetson

Surveyed 2026-07-29.

| Project | State | Notes |
|---|---|---|
| [RidgeRun OV5647 driver](https://developer.ridgerun.com/wiki/index.php?title=OmniVision_OV5647_Linux_driver_for_Jetson_Nano) | working, commercial | L4T 32.1 / JetPack 4.2. 1920x1080@30 BGGR10 through the ISP. Proves the sensor works with the T210 ISP. Sources are paid. |
| [jas-hacks Pi v1.3 camera driver](http://jas-hacks.blogspot.com/2019/08/jetson-nano-developing-pi-v13-camera.html) | alpha, 2019, unmaintained | L4T 32.2 prebuilt kernel and DTB. Modes: 2592x1944@15, 1080p30, 1280x960@45, 720p60. Useful mode and timing reference. |
| [Moore123/ov5647_jetson](https://github.com/Moore123/ov5647_jetson) | non-working | GPL-3, README states "Not Working YET By Now". |
| [GiraffAI blog series](https://www.giraffai.com/nvidia-jetson-nano/developing-ov5647-sensor-linux-device-driver-for-jetson-nano-part1) | partial, educational | Raw V4L2 capture only (640x480 RG10 stills), no ISP integration, series unfinished. |
| Arducam OV5647 for Jetson | discontinued | Required their proprietary Jetvariety adapter, not a native CSI driver. |
| Mainline kernel | infrastructure only | staging/media/tegra-video supports T210 VI/CSI capture and mainline has drivers/media/i2c/ov5647.c, but the NVIDIA ISP userspace is not part of mainline, so raw Bayer only. |

## Key references used by this implementation

- Mainline `drivers/media/i2c/ov5647.c`: register sequences, per-mode
  HTS/VTS and PLL setup (GPL-2.0)
- L4T `nvidia/drivers/media/i2c/imx219.c`: tegracam driver model
- L4T IMX219 camera dtsi and overlays per board: device-tree graph model
- Module quirk: the Pi camera holds the sensor unpowered until the
  connector's CAM0_PWDN line is raised. Verified live: with the line high
  the chip ACKs at 0x36 and ID regs 0x300A/0x300B read 0x56/0x47.
