# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""ColorChecker reference, colour conversions and raw frame reading."""

import numpy as np

# Published sRGB values of the 24 ColorChecker Classic patches, row by
# row from the brown "dark skin" patch; the last six are the grey row.
SRGB8 = [(115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
         (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
         (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
         (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
         (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
         (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]

GREYS = slice(19, 22)	# N8, N6.5, N5: the grey patches used for white balance
N65 = 20		# N6.5, the patch exposure is normalised to

M_XYZ = np.array([[0.4124, 0.3576, 0.1805],
                  [0.2126, 0.7152, 0.0722],
                  [0.0193, 0.1192, 0.9505]])
WHITE = M_XYZ @ np.ones(3)


def srgb_to_linear(c):
	c = np.asarray(c, float) / 255
	return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(lin):
	lin = np.clip(lin, 0, 1)
	return np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * lin ** (1 / 2.4) - 0.055)


def lab(rgb):
	x = (np.asarray(rgb, float) @ M_XYZ.T) / WHITE
	f = np.where(x > 216 / 24389, np.cbrt(x), (24389 / 27 * x + 16) / 116)
	return np.stack([116 * f[:, 1] - 16,
	                 500 * (f[:, 0] - f[:, 1]),
	                 200 * (f[:, 1] - f[:, 2])], -1)


REF = srgb_to_linear(SRGB8)
LREF = lab(REF)


def delta_e(rgb):
	return np.sqrt(((lab(np.clip(rgb, 1e-5, None)) - LREF) ** 2).sum(1))


def read_raw(path, width, height, black=16.0):
	"""Mean of all frames in a v4l2-ctl BG10 dump, as R, G, B planes.

	R32 hands over the 10-bit samples right-aligned and R35 and JetPack 7
	shift them to the top of 16 bits, so samples above 1023 are scaled
	down. The planes are half the frame size, one value per Bayer quad.
	"""
	a = np.fromfile(path, np.uint16).astype(np.float64)
	n = a.size // (width * height)
	if n == 0:
		raise ValueError(f"{path}: smaller than one {width}x{height} frame")
	a = a[:n * width * height].reshape(n, height, width).mean(0)
	if a.max() > 1023:
		a /= 64
	a -= black
	b = a[0::2, 0::2]
	g = (a[0::2, 1::2] + a[1::2, 0::2]) / 2
	r = a[1::2, 1::2]
	return np.stack([r, g, b], -1)


def parse_corners(text):
	"""'x,y;x,y;x,y;x,y' to a 4x2 array: centres of the dark skin, bluish
	green, white and black patches (top left, top right, bottom left,
	bottom right) in pixels of the image they refer to."""
	pts = [tuple(float(v) for v in p.split(",")) for p in text.split(";")]
	if len(pts) != 4:
		raise ValueError("need four corners")
	return np.array(pts)


def patch_centres(corners):
	tl, tr, bl, br = corners
	out = []
	for j in range(4):
		for i in range(6):
			u, v = i / 5, j / 3
			out.append((1 - u) * (1 - v) * tl + u * (1 - v) * tr +
			           (1 - u) * v * bl + u * v * br)
	return np.array(out)


def sample(image, centres, half):
	out = []
	for x, y in centres.astype(int):
		box = image[max(y - half, 0):y + half, max(x - half, 0):x + half]
		out.append(np.median(box.reshape(-1, box.shape[-1]), 0))
	return np.array(out)
