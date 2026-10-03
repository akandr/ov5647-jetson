#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""Estimate which colour temperature the ISP assigns to a scene.

The ISP blends its colour matrices by its own estimate of colour
temperature. This test brackets that estimate with two matrix sets:

    cct-markers.py make BASE.isp LO HI OUTDIR

writes OUTDIR/id.isp, with the identity at LO and at HI, and
OUTDIR/mark.isp, with the identity at LO and a marker matrix at HI. The
marker copies green into red, so the red of a coloured patch shows how
far the ISP blended towards HI. BASE.isp supplies the white balance
part; its matrices are dropped.

Capture the chart through the ISP with each file (capture-isp.sh), then

    cct-markers.py measure --corners '...' LO HI id.jpg mark.jpg

prints the blend weight and the colour temperature it implies, both for
blending linear in kelvin and linear in mired. Two brackets with
different HI agree only under the right assumption. The markers change
the image, and if AWB looks at the image after the matrix they may also
shift the estimate itself; treat the result as a guide.
"""

import argparse
import sys

import numpy as np
from PIL import Image

from colorchecker import N65, parse_corners, patch_centres, sample, srgb_to_linear

MARK = np.array([[0, 1, 0], [0, 1, 0], [0, 0, 1]], float)	# red output = green input
TESTS = (6, 8, 13, 14, 16)	# orange, moderate red, green, red, magenta


def matrix_lines(i, cct, m):
	t = np.asarray(m, float).T
	out = [f"colorCorrection.set[{i}].cct = {cct};"]
	out += [f"colorCorrection.set[{i}].ccMatrix[{k}] = "
	        f"{{ {t[k, 0]:.4f}, {t[k, 1]:.4f}, {t[k, 2]:.4f}, 0.0 }};" for k in range(3)]
	return out + [f"colorCorrection.set[{i}].ccMatrix[3] = {{ 0.0, 0.0, 0.0, 1.0 }};"]


def make(a):
	base = [l for l in open(a.base).read().splitlines()
	        if not l.startswith("colorCorrection")]
	for name, hi in (("id", np.eye(3)), ("mark", MARK)):
		lines = base + ["colorCorrection.numColorCorrectionMatrices = 2;"]
		lines += matrix_lines(0, a.lo, np.eye(3)) + matrix_lines(1, a.hi, hi)
		open(f"{a.outdir}/{name}.isp", "w").write("\n".join(lines) + "\n")
		print(f"{a.outdir}/{name}.isp")


def measure(a):
	centres = patch_centres(parse_corners(a.corners) * a.scale)
	def patches(path):
		img = np.asarray(Image.open(path).convert("RGB"), float)
		lin = srgb_to_linear(sample(img, centres, a.half))
		return lin / lin[N65, 1]
	i, k = patches(a.id_jpeg), patches(a.mark_jpeg)
	w = float(np.median([(i[n, 0] - k[n, 0]) / (i[n, 0] - i[n, 1]) for n in TESTS]))
	w = min(max(w, 0.0), 1.0)
	lin = a.lo + w * (a.hi - a.lo)
	mired = 1 / (1 / a.lo + w * (1 / a.hi - 1 / a.lo))
	print(f"weight {w:.2f}: {lin:.0f} K if blended in kelvin, {mired:.0f} K if in mired")


def main():
	ap = argparse.ArgumentParser(description=__doc__,
	                             formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = ap.add_subparsers(dest="cmd", required=True)
	m = sub.add_parser("make")
	m.add_argument("base"); m.add_argument("lo", type=int); m.add_argument("hi", type=int)
	m.add_argument("outdir")
	s = sub.add_parser("measure")
	s.add_argument("--corners", required=True)
	s.add_argument("--scale", type=float, default=1.0)
	s.add_argument("--half", type=int, default=15)
	s.add_argument("lo", type=float); s.add_argument("hi", type=float)
	s.add_argument("id_jpeg"); s.add_argument("mark_jpeg")
	a = ap.parse_args()
	make(a) if a.cmd == "make" else measure(a)


if __name__ == "__main__":
	sys.exit(main())
