# Driver internals

Notes for anyone changing the driver, the overlays or the tests.

## Capture path

    OV5647 --2-lane CSI-2--> NVCSI --> VI --DMA--> /dev/video0    raw Bayer, V4L2
                                       VI --> ISP --> NVMM buffers  Argus

- The sensor outputs 10-bit BGGR. The module has its own 25 MHz
  oscillator and regulators, so the driver handles one GPIO (enable)
  and no clocks. With the pin low the sensor does not answer on I2C.
- The driver is a tegracam driver. It supplies the register tables and
  a few operations. The framework builds the V4L2 subdevice, the media
  graph and the controls (`gain`, `exposure`, `frame_rate`,
  `sensor_mode`, `otp_data`, `group_hold`). Argus drives the sensor
  through the same controls.
- The mode list exists twice: register tables in the driver, timing
  properties in the device tree. They must agree, see below.

## Device tree overlays

- The installer merges the board's overlay into a copy of its DTB with
  `fdtoverlay` and points the `FDT` line of the default `extlinux.conf`
  entry at the copy. On JetPack 7 the DTB comes from UEFI. When the
  board booted without the overlay, the installer merges onto
  `/sys/firmware/fdt` and saves that tree as a snapshot. When it booted
  the merged tree, the installer merges onto the snapshot. It stops if
  the tree it would merge onto already carries the overlay.
- Nano and Xavier NX: the stock DTB has the camera graph for the IMX219.
  The overlay disables that sensor, adds the OV5647 and points the
  NVCSI endpoint at it.
- Orin: the stock DTB has no camera wiring. The overlay adds the whole
  graph, with swapped lane polarity on CAM0 as in NVIDIA's IMX219
  overlay.
- `--dual` installs the board's `*-dual-overlay.dts`, with a sensor node
  for each connector. A mode change has to be made in every sensor node
  of every overlay in `dt/`.
- `discontinuous_clk` must be `"no"` on the Nano and `"yes"` on the
  Orin. The Xavier NX works with either. The tables set a continuous
  clock (`0x4800 = 0x04`). With the gated clock values in mainline's
  tables (`0x24`, `0x34`) the Nano rejects every frame.
- `horizontal-mirror` and `vertical-flip` in the sensor node flip the
  image. The driver moves the readout window so that the Bayer order
  stays BGGR. A horizontal flip moves the left edge. A vertical flip
  moves the top and bottom edges, and moving only one of them drops a
  line and stalls the VI.

## Things that must agree

CI checks all of these (`.github/scripts/check-modes.py`).

- `pix_clk_hz` in each mode node must match the PLL multiplier
  (`0x3036`) of its table. A wrong value fails silently, and exposure
  and frame rate come out scaled by the error.
- `line_length`, `active_w` and `active_h` must match the table's line
  length and output size.
- The order of `frmfmt[]` in the driver must match the `modeN` nodes.
  The framework looks up properties by index.
- `discontinuous_clk` must be the value measured for the board.
- No mode table may write a nonzero value to the pad output enables
  `0x3000` to `0x3002`. The Orin's receiver never locked on a 640x480
  table that wrote `0xff` there.

## Register tables and mainline

Each register ends with the same value as in mainline
`drivers/media/i2c/ov5647.c` at 7.3-rc3, except:

- `0x4800`: continuous MIPI clock for Tegra.
- `0x0100`: stays 0. Separate start and stop tables drive streaming.
- `0x380c`, `0x380d`: the line length, written explicitly.
- `0x3821` bit 2 (`r_mirror_isp`): set, with no measurable effect.
- 1280x720 has its own table, the binned one with a 16:9 vertical
  window.
- 640x480 runs at the 87.5 MHz pixel clock of the other modes
  (`0x3036 = 0x69`), for 90 fps.

The driver also writes `0x5001 = 0` to turn off the sensor's own white
balance. Mainline does the same through `V4L2_CID_AUTO_WHITE_BALANCE`.
The `group_hold` control maps to the sensor's group hold (`0x3208`).
Gain and exposure written while it is 1 reach the sensor in the same
frame.

## Framework behaviour that looks like a bug

- The VI control `override_enable` decides whether tegracam writes the
  stored controls back at stream start. It defaults to 0 and Argus sets
  it to 1. The driver writes gain and exposure back itself.
- At every stream start the driver sets the frame length for the mode's
  default rate from the device tree. A frame rate set before streamon
  is lost unless `override_enable=1`.
- A control write with the current value is dropped. Sweeps must change
  the value each step.
- After an Argus pipeline the VI keeps its buffers, and raw capture
  returns nothing until the sensor driver is rebound.
- The VI starts every line at a 64-byte boundary. R35 and JetPack 7
  report a 2592-byte stride for the 1296-wide mode. Every second line
  then lands 16 pixels off. Ask for `bytesperline=2624`.
- JetPack 7 ships the tegracam headers without the generated
  `nvidia/conftest.h`. `driver/compat/` replaces it, with each value
  checked against L4T r39.2.

## Debugging

- `/sys/kernel/debug/ov5647-<bus>-0036/`: `regs` dumps the main register
  ranges. `reg` reads one register (`echo 0x300a > reg; cat reg`) or
  writes one (`echo '<addr> <value>' > reg`). `test_pattern` takes
  `off`, `bars` or `squares`. The sensor answers only while streaming.
- `v4l2-ctl --get-ctrl otp_data` returns the module's one-time
  programmable identity. Reading it needs the sensor's internal clock,
  so the driver streams briefly at probe.
- An error on every frame in dmesg (on the Nano
  `tegra_channel_error_status`) points to the link clocking. A capture
  with no frames at all points to mode timing, lanes, the ribbon or a
  wrong `discontinuous_clk`. Short frames point to a geometry mismatch
  between the table and the device tree.
- An empty raw capture can also come from a stale process holding the
  device (`sudo fuser -v /dev/video0`).
