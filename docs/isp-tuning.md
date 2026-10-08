# Colour on the Jetson ISP

The modules used here are the NoIR variant of the Pi Camera v1, with no
infrared cut filter. `isp/camera_overrides_noir.isp` corrects the
colours that Argus delivers on L4T R32 and R35 under LED light.
Outdoors the tuning failed, see [Outdoors](#outdoors).

- Sources A, B and C are LED sources that differ in spectrum, intensity
  and distance from the chart. Under them the mean ΔE is 31 to 35 with
  the generic tuning and 10 to 14 with the file.
- The numbers are the mean CIE76 ΔE over the 18 colour patches of a
  ColorChecker Classic, measured on the ISP's JPEG output. A ΔE of 2 to
  3 is about what the eye notices.
- The README has the install commands.
- The override keys are not publicly documented. Their names come from
  the generic tuning that L4T stores as text in `libnvscf.so`, and the
  effect of each key was measured.

| generic L4T tuning | `camera_overrides_noir.isp` |
|---|---|
| ![ColorChecker, generic tuning](img/chart-generic.jpg) | ![ColorChecker, indoor override](img/chart-tuned.jpg) |

The photos come from the Xavier NX (L4T R35). The chart is lit by LED
source B.

## Results

![Mean ΔE indoors, both boards, three sources](img/delta-e-indoor.png)

![The lab, outdoors and in the garage](img/lab.jpg)

Calibrated it is not. The numbers compare files under the same
conditions and say little about absolute accuracy.

## Outdoors

The outdoor tuning failed. The NoIR module records near infrared along
with visible light. Foliage reflects it strongly and comes out pale
violet grey, and the infrared adds to every colour by an amount that
depends on the material. A colour matrix cannot remove it.

| generic L4T tuning | best attempt, `saturation=1.5` | phone, a day earlier |
|---|---|---|
| ![Garden, generic tuning](img/garden-generic.jpg) | ![Garden, best daylight attempt](img/garden-daylight.jpg) | ![Garden, phone](img/garden-phone.jpg) |

- Both boards captured the chart in the garden every four minutes for
  about an hour, in shade and in sun. The generic tuning scored ΔE 45
  to 47.
- The best attempt, a daylight white point and matrix plus
  `saturation=1.5` on `nvarguscamerasrc`, reached 23 to 30, about twice
  the indoor error. A matrix fitted to the raw frames scored 18 to 22 in
  shade and 23 to 28 in sun, against 9 to 16 under the LEDs.
- The override file of the best attempt is kept as
  `isp/camera_overrides_noir_daylight.isp`, for reference only. Its
  colours are as poor as the middle photo shows, and in dim light it
  crushes the shadows in the binned modes.
- Daylight sits far from the LED white points (figure below).
- A module with an infrared cut filter should do much better with the
  same procedure.

![Raw white points of the sources against the OV5647 locus](img/white-points.png)

## What the indoor file changes

- **White balance.** The generic tuning is made for an IMX091. Its AWB
  clamps the estimate to that sensor's grey line and applies a gain of
  about 1.65 to red and blue. On this sensor the image turns magenta.
  The file enters this sensor's whites in `awb.v4.FusionLights` and
  opens the clamps (`LowU`, `HighU`, `GrayLineThickness`,
  `NumGrayLineSoftClampPoints`).
- **Lux prior.** The file sets `awb.v4.FusionUseLux = FALSE`. The
  prior's thresholds and weights are tuned for another sensor. Outdoors,
  with a daylight white entered and the prior on, the greys came out
  magenta and blue (a\* +10, b\* -13). With it off they came out at
  a\* -2.5, b\* +3.9. Indoors it made no difference.
- **Colour matrices.** One per source in `colorCorrection.set[i]`, and
  source C again at 8500 K without the added saturation. The ISP blends
  them by its own colour temperature estimate.

## Findings

- **The sensor's own white balance.** The first driver version left the
  OV5647's automatic white balance on (register 0x5001), so the sensor
  scaled red and blue in the raw output. White points measured that way
  needed an empirical correction (R x1.08, B x1.12). The driver now
  turns it off, and the white points were measured again without any
  correction.
- **Modules differ.** The white points follow the module and repeat
  within 0.01 on each board tested. The two modules differ by about 3%
  in R/G and 6% in B/G, and the files use their mean.
- **Black level.** The generic tuning and the indoor file subtract none.
  The daylight file sets `opticalBlack.float.manualBias*` to 0.0146 of
  full scale. That improved ΔE by about 1 outdoors. Indoors the effect
  ranged from 1.1 better to 1.6 worse. In dim light at 1296x972 the gain
  is high and the sensor's black level lower, so the subtraction crushed
  the chart's whole grey row to 16 of 255.
- **White balance error.** Under source C with an identity matrix the
  grey came out with red 11% low. The fitted matrix amplified that to
  26%. The ISP's AWB also weighs the scene, so its output white never
  equals an entered white exactly.

## Editing an override file

- `tools/isp/dump-defaults.sh` lists the keys of the generic tuning
  with their defaults.
- Argus rejects a bad line and stops the camera.
  `journalctl -u nvargus-daemon` names the line, and
  `tools/isp/probe-keys.sh` tests many values in one run. Measured
  limits: `HighU` up to 4, `GrayLineThickness` up to 1, `awb.v4.Method`
  0 to 3. A matrix coefficient of 3.74 was accepted and 4.04 rejected.
- Matrices go in `colorCorrection.set[i].cct` and `.ccMatrix[0..3]`.
  The variants `cct[i]`, `ccMatrix[i][j]` and `colorCorrectionMatrix[i]`
  are not parsed and turn the image black.
- Matrix labels of 2000 and 12000 K stopped the camera with no log
  line. 2500 and 9000 K work.
- Each `ccMatrix` row is an input channel, the transpose of the
  libcamera layout. A matrix that only scales red and blue had almost no
  effect, so white balance has to come from `FusionLights`.
- After each change delete `nvcam_cache_*.bin` next to the override and
  restart `nvargus-daemon`.
- `tools/isp/cct-markers.py` measures which colour temperature the ISP
  assigns to a scene.

## Method

- Raw frames at 2592x1944, gain 1x, with the white patch below 85% of
  full scale. Each patch is sampled over 40 by 40 pixels per Bayer
  plane. Black is 16 of 1023.
- White balance from the three middle grey patches (N8, N6.5, N5):

  $$ g_c = \frac{\sum G}{\sum c}, \quad c \in \{R, G, B\} $$

- A 3x3 matrix from white-balanced camera RGB to linear sRGB, with rows
  summing to one, fitted to minimise the mean ΔE of the 18 colour
  patches plus a penalty towards identity:

  $$ M^* = \arg\min_M \frac{1}{18} \sum_{k=1}^{18} \Delta E_{76}\big(\mathrm{Lab}(M\,\mathbf{x}_k),\ \mathrm{Lab}_k\big) + \lambda \lVert M - I \rVert_F^2 $$

  λ is 0.1 for the LED matrices and 0.3 for the daylight matrix. The
  LED matrices are fitted to both modules together.
- A saturation of 1.2 is folded into the LED matrices with luma
  preserved:

  $$ M_s = \big((1-s)\,\mathbf{1}\mathbf{y}^\top + s I\big) M, \quad \mathbf{y} = (0.2126, 0.7152, 0.0722), \ s = 1.2 $$

- Whites go into `awb.v4.FusionLights[i] = {R, Gr, Gb, B}`, scaled so
  that the largest is 900. For source B, raw grey R/G 0.900 and B/G
  0.662 become `{810, 900, 900, 596}`. The JSON sources in `isp/` give
  the slots and the matrix labels.
- The ISP is scored on its JPEG: decoded to linear, scaled so that N6.5
  matches the reference, converted to Lab. The score includes the ISP's
  tone curve and sharpening.

## Reproducing

The tools are in `tools/isp/`. The Python tools need numpy and Pillow,
`fit.py` also SciPy. The shell scripts run on the board.

1. Capture the chart in raw under each source. If the capture comes
   back empty after an Argus pipeline, add `REBIND=1` and run as root.

       tools/isp/capture-raw.sh chart-B /dev/video0 10000 20000 40000

2. Fit. The corners are the centres of the dark skin, bluish green,
   white and black patches in full-resolution pixels. `--preview` draws
   the sampled squares. Several `--capture` arguments give one joint
   matrix.

       tools/isp/fit.py --capture chart-B/e20000.bin '444,465;2274,510;348,1581;2322,1611' \
               --lambda 0.1 --out fit-B.json --preview check-B

3. Describe the sources in a JSON file like those in `isp/` and build
   the override. The header of `make-override.py` lists the keys.

       tools/isp/make-override.py my.json > my.isp

4. Capture through the ISP and score. `capture-isp.sh` captures mode 2,
   at half resolution, so full-resolution corners take `--scale 0.5`.
   `ARGUS` passes properties to `nvarguscamerasrc`, such as a fixed
   exposure.

       sudo tools/isp/capture-isp.sh none generic.jpg
       sudo tools/isp/capture-isp.sh my.isp tuned.jpg
       sudo ARGUS='exposuretimerange="300000 300000" gainrange="1 1"' \
               tools/isp/capture-isp.sh my.isp tuned-fixed.jpg
       tools/isp/score.py --scale 0.5 --corners '...' generic.jpg tuned.jpg

`capture-isp.sh` restores the previous override when it exits. If the
board loses power during a capture, the test file stays installed.

## Other measurements

![Sensor black level against analog gain at 1296x972](img/black-vs-gain.png)

- In the binned modes the sensor's black level falls with analog gain,
  from about 15 of 1023 below 8x to about 2 at 64x. At full resolution
  it stays near 16 up to 32x. Changing the BLC registers (0x4000 to
  0x4005) did not keep it constant.
- Argus auto exposure settles within 5% in 2.3 to 2.6 s after a step in
  light, without oscillation.

![Argus auto exposure after a step in scene light](img/ae-step.png)

- Exposure is linear from 1 to 30 ms.
- A mains-powered ceiling light shows 100 Hz banding at short
  exposures, 1 to 2% deep.
- The matrices raise red and blue noise by 15 to 40%. Luma noise stays
  the same.

## Limits

- The module on the Xavier NX (e80cca6142) keeps a tint with the indoor
  file, b\* +9 under source A and a\* -7 under source C. The module on
  the Nano (88110a5d34) stays within 3 of neutral.
- Source A does worst. Its blue channel is weak, and the raw fit only
  reaches ΔE 12 to 16.
- The tone curve comes from the generic tuning, and neither file
  corrects lens shading, so the corners are darker.
- The ColorChecker has seen better days.
