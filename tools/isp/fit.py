#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""Fit white balance and a colour matrix to raw ColorChecker captures.

    fit.py --capture xavier.bin '630,300;2316,360;399,1260;2136,1575' \\
           --capture orin.bin '444,465;2274,510;348,1581;2322,1611' \\
           --lambda 0.1 --out fit.json --preview check

Each capture is a v4l2-ctl BG10 dump of one light source, with the
centres of the four corner patches in full-resolution pixels (dark skin,
bluish green, white, black). The grey patches give each capture's white
balance; one matrix is then fitted to all captures together.

The matrix maps white-balanced camera RGB to linear sRGB. Its rows sum
to one, so a grey stays grey, which leaves six free coefficients. The
fit minimises the mean CIE76 delta E over the 18 colour patches plus
lambda times the squared distance of the matrix from the identity.

--preview writes PREFIX-N.png per capture with the sampled squares drawn
on a white-balanced image, to check the corners.
"""

import argparse
import json
import sys

import numpy as np
from scipy.optimize import minimize

from colorchecker import GREYS, REF, LREF, delta_e, lab, linear_to_srgb, \
	parse_corners, patch_centres, read_raw, sample


def matrix(p):
	return np.array([[p[0], p[1], 1 - p[0] - p[1]],
	                 [p[2], p[3], 1 - p[2] - p[3]],
	                 [p[4], p[5], 1 - p[4] - p[5]]])


def mean_de(m, xs):
	return np.mean([np.sqrt(((lab(np.clip(x[:18] @ m.T, 1e-5, None)) -
	                          LREF[:18]) ** 2).sum(1)).mean() for x in xs])


def main():
	ap = argparse.ArgumentParser(description=__doc__,
	                             formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--capture", nargs=2, action="append", required=True,
	                metavar=("FILE", "CORNERS"))
	ap.add_argument("--size", default="2592x1944", help="frame size, WxH")
	ap.add_argument("--black", type=float, default=16.0, help="black level, 10-bit")
	ap.add_argument("--half", type=int, default=20,
	                help="half the sampled square, in half-resolution pixels")
	ap.add_argument("--lambda", dest="lam", type=float, default=0.1)
	ap.add_argument("--out", required=True)
	ap.add_argument("--preview")
	a = ap.parse_args()
	w, h = (int(v) for v in a.size.split("x"))

	caps, xs = [], []
	for n, (path, text) in enumerate(a.capture):
		rgb = read_raw(path, w, h, a.black)
		centres = patch_centres(parse_corners(text) / 2)
		raw = sample(rgb, centres, a.half)
		g = raw[GREYS].sum(0)
		wb = g[1] / g
		x = raw * wb
		x *= REF[GREYS, 1].sum() / x[GREYS, 1].sum()
		xs.append(x)
		caps.append({"file": path, "white": [g[0] / g[1], g[2] / g[1]],
		             "wb": wb.tolist(), "patches": raw.tolist(),
		             "de_wb_only": float(delta_e(x)[:18].mean())})
		if a.preview:
			from PIL import Image, ImageDraw
			img = linear_to_srgb(rgb * wb / np.percentile(rgb * wb, 99.5))
			im = Image.fromarray((img * 255).astype(np.uint8))
			d = ImageDraw.Draw(im)
			for cx, cy in centres:
				d.rectangle([cx - a.half, cy - a.half, cx + a.half, cy + a.half],
				            outline=(255, 255, 255), width=3)
			im.save(f"{a.preview}-{n}.png")

	cost = lambda p: mean_de(matrix(p), xs) + a.lam * ((matrix(p) - np.eye(3)) ** 2).sum()
	best = None
	for p0 in ([1, 0, 0, 1, 0, 0], [1.5, -0.3, -0.3, 1.6, -0.1, -0.5],
	           [2, -0.5, -0.5, 2, -0.2, -0.8]):
		r = minimize(cost, np.array(p0, float), method="Nelder-Mead",
		             options={"maxiter": 40000, "xatol": 1e-7, "fatol": 1e-7})
		if best is None or r.fun < best.fun:
			best = r
	m = matrix(best.x)

	out = {"lambda": a.lam, "ccm": m.tolist(), "de": float(mean_de(m, xs)),
	       "max_coefficient": float(np.abs(m).max()),
	       "white": np.mean([c["white"] for c in caps], 0).tolist(),
	       "captures": caps}
	json.dump(out, open(a.out, "w"), indent=1)
	for c in caps:
		print(f"{c['file']}: white R/G {c['white'][0]:.3f} B/G {c['white'][1]:.3f}, "
		      f"delta E with white balance only {c['de_wb_only']:.1f}")
	print(f"matrix, lambda {a.lam}: mean delta E {out['de']:.1f}, "
	      f"largest coefficient {out['max_coefficient']:.2f}")
	print(np.array2string(m, precision=3, suppress_small=True))


if __name__ == "__main__":
	sys.exit(main())
