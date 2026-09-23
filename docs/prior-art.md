# Prior art: OV5647 on Jetson

Surveyed 2026-07-29; the mainline row rechecked 2026-09-15.

| Project | State | Notes |
|---|---|---|
| [RidgeRun OV5647 driver](https://developer.ridgerun.com/wiki/index.php?title=OmniVision_OV5647_Linux_driver_for_Jetson_Nano) | working, commercial | L4T 32.1 / JetPack 4.2. 1920x1080@30 BGGR10 through the ISP. Proves the sensor works with the T210 ISP. Sources are paid. |
| [jas-hacks Pi v1.3 camera driver](http://jas-hacks.blogspot.com/2019/08/jetson-nano-developing-pi-v13-camera.html) | alpha, 2019, unmaintained | L4T 32.2 prebuilt kernel and DTB. Modes: 2592x1944@15, 1080p30, 1280x960@45, 720p60. Useful mode and timing reference. |
| [Moore123/ov5647_jetson](https://github.com/Moore123/ov5647_jetson) | non-working | GPL-3, README states "Not Working YET By Now". |
| [GiraffAI blog series](https://www.giraffai.com/nvidia-jetson-nano/developing-ov5647-sensor-linux-device-driver-for-jetson-nano-part1) | partial, educational | Raw V4L2 capture only (640x480 RG10 stills), no ISP integration, series unfinished. |
| Arducam OV5647 for Jetson | discontinued | Required their proprietary Jetvariety adapter, not a native CSI driver. |
| Mainline kernel | infrastructure only, T210 only | `staging/media/tegra-video` covers Tegra20/30 and T210; T194 and T234 appear in neither its Makefile nor its Kconfig. Mainline has `drivers/media/i2c/ov5647.c`, but the NVIDIA ISP userspace is not part of mainline, so raw Bayer only. See below. |

## Why not just run mainline?

It is a fair question on the Nano, and the answer is narrower than it
looks. Mainline has all the pieces for that board: the VI and CSI driver
in staging, a `drivers/media/i2c/ov5647.c` with four modes and the usual
controls, a device tree for the Jetson Nano 2GB
(`tegra210-p3541-0000.dts`) with VI, CSI and the camera I2C bus already
enabled. What it does not have is the camera itself: no sensor node and
no port graph, which is a device-tree question rather than a driver one.

Two details decide whether such a tree would work, and both come out in
mainline's favour:

- The continuous MIPI clock this receiver needs is not a patch. The
  mainline driver reads `clock-noncontinuous` from the endpoint and
  gates the clock lane only when it is present, overriding what its own
  mode tables program. Leaving the property out asks for the clock this
  port wants.
- `SBGGR10_1X10` is among the formats `tegra210.c` accepts, so the
  sensor's native format needs no conversion.

What mainline cannot offer on any Jetson is the ISP: no hardware
debayer, no auto exposure or white balance, and no NVMM buffers for
CUDA or the encoders. That is the reason this driver sits on tegracam
instead. Mainline is the better answer for raw Bayer on a Nano and no
answer at all on a Xavier NX or an Orin.

## Key references used by this implementation

- Mainline `drivers/media/i2c/ov5647.c`: register sequences, per-mode
  HTS/VTS and PLL setup (GPL-2.0)
- L4T `nvidia/drivers/media/i2c/imx219.c`: tegracam driver model
- L4T IMX219 camera dtsi and overlays per board: device-tree graph model
- The 1280x720 mode here is not taken from any of the above. It is the
  binned mode's own register table with the readout window cut to 1464
  array rows, which is what makes a frame short enough for 60 fps; the
  jas-hacks list showing a 720p60 mode is corroboration that the sensor
  reaches it, not a source for the timings.
- Module quirk: the Pi camera holds the sensor unpowered until the
  connector's CAM0_PWDN line is raised. Verified live: with the line high
  the chip ACKs at 0x36 and ID regs 0x300A/0x300B read 0x56/0x47.
