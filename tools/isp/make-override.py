#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""Build a camera_overrides.isp file from measured white points and matrices.

    make-override.py isp/camera_overrides_noir.json > camera_overrides.isp

The JSON lists the light sources. For each one:

  white       raw R/G and B/G of a grey patch, from fit.py
  slots       which of the eight awb.v4.FusionLights entries it fills
  cct         the colour temperature label of its matrix
  ccm         3x3 matrix from fit.py (camera RGB to linear sRGB, rows
              summing to one)
  saturation  optional, folded into the matrix with luma preserved
  fusion      optional, an explicit {R, Gr, Gb, B} that replaces the
              computed one

and at the top level:

  correction  factors for R and B applied to every white before scaling
  init_light  awb.v4.FusionInitLight
  header      comment lines for the top of the file

A white becomes {R, G, G, B} scaled so that the largest is 900, after
the correction. Matrices are written transposed, because each ccMatrix
row is an input channel.
"""

import json
import sys

import numpy as np

LUMA = np.array([0.2126, 0.7152, 0.0722])
CLAMPS = [("LowU", "0.05"), ("HighU", "4.0"), ("GrayLineThickness", "1.0"),
          ("NumGrayLineSoftClampPoints", "0")]


def fusion_light(white, correction):
	r, b = white[0] * correction[0], white[1] * correction[1]
	s = 900 / max(r, 1, b)
	return [round(r * s), round(s), round(s), round(b * s)]


def saturate(m, s):
	return ((1 - s) * np.outer(np.ones(3), LUMA) + s * np.eye(3)) @ m


def main():
	cfg = json.load(open(sys.argv[1]))
	out = [f"# {line}".rstrip() for line in cfg.get("header", [])]
	if out:
		out.append("")

	out += ["# White balance: the white of each source, raw R, Gr, Gb and B",
	        "# scaled so that the largest is 900. The clamps the generic tuning",
	        "# puts on the white estimate are opened up."]
	slots = {}
	for src in cfg["sources"]:
		v = src.get("fusion") or fusion_light(src["white"], cfg["correction"])
		for i in src["slots"]:
			slots[i] = (v, src["name"])
	if sorted(slots) != list(range(8)):
		sys.exit("the sources must fill all eight FusionLights slots")
	for i in range(8):
		v, name = slots[i]
		out.append(f"awb.v4.FusionLights[{i}] = {{{v[0]},{v[1]},{v[2]},{v[3]}}}; # {name}")
	out.append(f"awb.v4.FusionInitLight = {cfg['init_light']};")
	for prefix in ("awb.", "awb.v4."):
		out += [f"{prefix}{k} = {v};" for k, v in CLAMPS]

	sets = sorted(cfg["sources"], key=lambda s: s["cct"])
	out += ["", "# Colour matrices by the colour temperature the ISP estimates. Each",
	        "# row is an input channel.",
	        f"colorCorrection.numColorCorrectionMatrices = {len(sets)};"]
	for i, src in enumerate(sets):
		t = saturate(np.array(src["ccm"]), src.get("saturation", 1.0)).T
		out.append(f"colorCorrection.set[{i}].cct = {src['cct']};")
		for k in range(3):
			out.append(f"colorCorrection.set[{i}].ccMatrix[{k}] = "
			           f"{{ {t[k, 0]:.4f}, {t[k, 1]:.4f}, {t[k, 2]:.4f}, 0.0 }};")
		out.append(f"colorCorrection.set[{i}].ccMatrix[3] = {{ 0.0, 0.0, 0.0, 1.0 }};")
	print("\n".join(out))


if __name__ == "__main__":
	main()
