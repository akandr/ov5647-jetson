#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""Score ISP output on a ColorChecker.

    score.py --corners '315,150;1158,180;200,630;1068,788' generic.jpg tuned.jpg

CORNERS are the centres of the dark skin, bluish green, white and black
patches in pixels of the JPEG. With --scale 0.5 they can be given in
full sensor resolution for a 1296x972 capture.

The JPEG is decoded from sRGB to linear and scaled so that N6.5 matches
the reference. For each file the script prints the mean CIE76 delta E
of the 18 colour patches and of the six greys, the mean a* and b* of
the greys N8 to N3.5 (zero is neutral) and the median chroma relative to the
reference (1.0 is right, below 1 is undersaturated).
"""

import argparse
import os

import numpy as np
from PIL import Image

from colorchecker import LREF, N65, REF, delta_e, lab, parse_corners, \
	patch_centres, sample, srgb_to_linear


def main():
	ap = argparse.ArgumentParser(description=__doc__,
	                             formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--corners", required=True)
	ap.add_argument("--scale", type=float, default=1.0)
	ap.add_argument("--half", type=int, default=15)
	ap.add_argument("jpeg", nargs="+")
	a = ap.parse_args()
	centres = patch_centres(parse_corners(a.corners) * a.scale)
	print(f"{'file':32s} {'dE colour':>9s} {'dE grey':>8s} {'a*':>6s} {'b*':>6s} {'chroma':>7s}")
	for path in a.jpeg:
		img = np.asarray(Image.open(path).convert("RGB"), float)
		lin = srgb_to_linear(sample(img, centres, a.half))
		lin *= REF[N65, 1] / lin[N65, 1]
		de = delta_e(lin)
		lb = lab(np.clip(lin, 1e-5, None))
		chroma = np.hypot(lb[:18, 1], lb[:18, 2]) / np.hypot(LREF[:18, 1], LREF[:18, 2])
		print(f"{os.path.basename(path)[:32]:32s} {de[:18].mean():9.1f} {de[18:].mean():8.1f} "
		      f"{lb[19:23, 1].mean():6.1f} {lb[19:23, 2].mean():6.1f} {np.median(chroma):7.2f}")


if __name__ == "__main__":
	main()
