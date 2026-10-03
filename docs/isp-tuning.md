# Colour on the Jetson ISP

The two modules used here turned out to be the NoIR variant of the Pi
Camera v1, with no infrared cut filter. That came to light late, when
a black hoodie in the sun came out light grey.

This page covers the effect of the missing filter outdoors, what the
Jetson ISP adds to it, and an override file measured under artificial
light, where the filter matters much less. The ISP results come from
L4T R35 on a Xavier NX through Argus. The raw frames come from V4L2 on
the Xavier NX and the Orin Nano.

Little of this is publicly documented. The key names come from the
generic tuning that L4T installs as text inside `libnvscf.so`, and a
few details from forum threads. The effect of each key was found by
measuring the images it produces.

![The generic tuning and this one, the same sensor and source](img/chart-before-after.jpg)

| source | generic L4T tuning | `isp/camera_overrides_noir.isp` |
|---|---|---|
| A, warm LED | 41.7 | 17.9 |
| B, neutral LED | 37.3 | 11.3 |
| C, cool LED | 32.3 | 11.1 |
| B with a second, warm source | 39.2 | 13.1 |

The numbers are the mean ΔE (CIE76) over the 18 colour patches of a
ColorChecker Classic, measured on the ISP's JPEG output. Lower is
better. A difference of 2 to 3 is about the limit of what the eye
sees. Sources A, B and C differ in spectrum, intensity and distance
from the chart. The file goes to
`/var/nvidia/nvcam/settings/camera_overrides.isp`, and its first lines
give the install commands.

## The lab

![The lab, outdoors and in the garage](img/lab.jpg)

Calibrated it is not. The numbers on this page compare tunings under
the same conditions and say little about absolute colour accuracy.

## Outdoors: the infrared

![Generic tuning, the daylight override, and a phone, same garden, same evening](img/garden-comparison.jpg)

Left, the ISP with its generic tuning. Middle, the first override,
made for daylight only and captured with `saturation=1.5
exposurecompensation=0.3` on `nvarguscamerasrc`. Right, an iPhone for
scale. Leaves reflect near infrared strongly. Without a filter that
light reaches the red, green and blue pixels alike, and the sensor sees
bright, colourless foliage. A colour matrix cannot restore the green,
because the sensor never recorded it.

The white points show the same in numbers. Under the LED sources a
grey patch sits near the white locus of the OV5647 with an infrared
filter, taken from the Raspberry Pi tuning for the same sensor. In
daylight shade it lies far from that locus, with red and blue both
raised by infrared.

![Raw white points of the sources against the OV5647 locus](img/white-points.png)

In daylight, a colour matrix fitted to the chart reaches a mean ΔE of
18 only with coefficients above 6, and such a matrix amplifies noise
six times. With coefficients kept near 1.5 the fit stays at ΔE 38.
Under the LED sources the same fit reaches 9 to 14 with coefficients
below 3, close to the matrix Raspberry Pi publishes for the module with
the filter. The method works indoors. Outdoors the sensor lacks the
information.

## What the generic tuning does

L4T falls back to a tuning stored as text in `libnvscf.so`. Its white
balance is calibrated for an IMX091. On this sensor it applies a gain
of about 1.65 to red and blue, measured on the chart, and the picture
turns magenta under any light.

- **White balance.** AWB clamps its estimate to the IMX091's grey line
  (`awb[.v4].LowU`, `HighU`, `GrayLineThickness`,
  `GrayLineSoftClamp`). The gains it then applies match the white of
  that sensor's starting light, D50. Entering this sensor's whites in
  `awb.v4.FusionLights` and opening the clamps fixes it. The output
  white does not equal the entered white exactly, because AWB also
  looks at the scene. The entries needed a correction of about R x1.08
  and B x1.12, found by measuring two settings and interpolating.
- **Colour matrix.** The ISP behaves as if it normalised each row of
  `colorCorrection.set[i].ccMatrix` to sum to one. The matrix therefore
  cannot correct white balance, and a matrix that only scales red and
  blue has almost no effect. Each row is an input channel, the
  transpose of the libcamera layout.
- **Matrix choice.** The ISP picks and blends matrices by its own
  estimate of colour temperature. It makes that estimate the IMX091's
  way, so the number has little to do with the source. The blending
  looks linear in mired. Two pairs of marker matrices (2500/9000 K and
  2500/5000 K) agree with each other only under that assumption, and
  both put source B near 4600 K. A real matrix labelled 4640 K then did
  worse than expected, so the markers probably bias the reading. The
  final labels were set by measuring ΔE. Moving them by 500 to 1000 K
  changed the result by 0.2 to 1.5.
- **Validation.** Argus checks the override file. A rejected line stops
  the camera, and `journalctl -u nvargus-daemon` names the line. A file
  with one key written several times, each with a different value,
  shows which values are accepted. `HighU` accepts up to 4,
  `GrayLineThickness` up to 1, and `awb.v4.Method` 0 to 3. A matrix
  coefficient of 4.04 was rejected and 3.74 accepted. Matrices labelled
  2000 and 12000 K stopped the camera with no log line. 2500 and 9000 K
  work. A matrix set in any syntax other than
  `colorCorrection.set[i].cct` and `.ccMatrix[0..3]` is ignored and
  turns the image black. After any change, delete `nvcam_cache_*.bin`
  next to the override and restart `nvargus-daemon`.

## Method

The raw frames are 2592x1944, taken through V4L2 at gain 1x, with the
exposure set to keep the white patch below 85% of full scale. Each of
the 24 patches is sampled over 40 by 40 pixels in each Bayer plane at
its centre, away from the chart's scratches. Black is 16 of 1023.

White balance comes from the three middle grey patches (N8, N6.5,
N5):

$$ g_c = \frac{\sum G}{\sum c}, \quad c \in \{R, G, B\} $$

The colour matrix maps white-balanced camera RGB to linear sRGB. Its
rows sum to one so that grey stays grey, which leaves six free
coefficients. The fit minimises the mean CIE76 ΔE over the 18 colour
patches against the chart's published sRGB values, with a penalty
that keeps the matrix near identity:

$$ M^* = \arg\min_M \frac{1}{18} \sum_{k=1}^{18} \Delta E_{76}\big(\mathrm{Lab}(M\,\mathbf{x}_k),\ \mathrm{Lab}_k\big) + \lambda \lVert M - I \rVert_F^2 $$

λ is 0.1 indoors and 3 for daylight. The Xavier NX and the Orin Nano
modules are fitted together. A saturation factor s is then folded in
with luma preserved:

$$ M_s = \big((1-s)\,\mathbf{1}\mathbf{y}^\top + s I\big) M, \quad \mathbf{y} = (0.2126, 0.7152, 0.0722), \ s = 1.2 $$

The result goes into `ccMatrix` transposed. A factor of 1.3 scored
worse on the ISP output, and 1.4 pushes a coefficient past the limit
of 4.

Light adds linearly in raw, so one source can be measured while
another is on. A frame with both, minus a frame with the first alone,
shows the chart under the second alone. One extra source was measured
this way, and its white point came within 0.03 of source A's.

The ISP is scored on its own output. The JPEG is decoded from sRGB to
linear, scaled so that N6.5 matches the reference and converted to
Lab, and ΔE is computed per patch. This score includes the ISP's tone
curve and sharpening, which the raw fit does not see, so it reads
higher than the fit.

## Other measurements

![Sensor black level against analog gain](img/black-vs-gain.png)

The sensor's black level falls with analog gain. It is about 15 of
1023 up to 8x and 11 at 15.5x, steps down at 16x, and reaches about 2
at 64x with two thirds of the pixels clipped at zero. Both boards
agree. Changing the BLC registers (0x4000 to 0x4005) did not hold it.
A cap on analog gain at 15.9x, with digital gain from the ISP above
that, removes the clipping but lowers the signal to noise ratio in low
light. The driver applies no cap.

![Argus auto exposure after a step in scene light](img/ae-step.png)

With this driver, Argus auto exposure settles within 5% in 2.3 to
2.6 s after a step in either direction, without oscillation. In steady
light the frame mean varies by 0.1% from frame to frame.

- Exposure is linear from 1 to 30 ms.
- The one mains-powered ceiling light tested shows 100 Hz banding at
  short exposures, 1 to 2% deep.
- With the override, luma noise on the grey patches is unchanged. Red
  and blue noise rise by 15 to 40%, the cost of the matrix.

## Limits

- A grey keeps a slight green tint on the output, with a\* at about -5
  to -7 under B and C. Moving a source's white in the file barely
  changes it.
- Source A, the warmest, does worst. Its blue channel is weak, and the
  raw fit itself only reaches ΔE 14.
- The daylight entry was measured once, in shade, and tested only in
  an earlier, daylight-only file. This file is untested outdoors.
- The tone curve and the missing lens shading correction come from the
  generic tuning. The corners are darker, and the remaining ΔE includes
  that.
- The ColorChecker has seen better days.
- All of this was measured on L4T R35. The Nano (R32) uses the same
  mechanism and is untested. On the Orin (JetPack 7) Argus does not run
  for this sensor, so there is no ISP to tune. Its raw frames went into
  the fits.
- A module with an infrared cut filter should do much better outdoors
  with the same procedure.
