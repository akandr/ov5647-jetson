#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
"""Check that the driver's modes and the device tree's agree.

tegracam indexes frmfmt[] and the modeX nodes separately and assumes they
line up. When they do not, the failure arrives at probe or at stream
start and looks like something else.

Both ways of breaking it have happened here: a mode node copied from
another board's overlay, and frmfmt[] drifting out of enum order.

Exits non-zero on the first disagreement.
"""
import re
import sys
from pathlib import Path


def blad(msg):
    print("FAIL " + msg)
    sys.exit(1)


def tryby_sterownika(tbls: str):
    """Mode names in enum order, and frmfmt entries in table order."""
    m = re.search(r"\nenum \{\n(.*?)\n\};", tbls, re.S)
    if not m:
        blad("no mode enum in ov5647_mode_tbls.h")
    enum = [w.strip().rstrip(",") for w in m.group(1).split("\n") if w.strip()]

    m = re.search(r"ov5647_frmfmt\[\] = \{\n(.*?)\n\};", tbls, re.S)
    if not m:
        blad("no frmfmt table in ov5647_mode_tbls.h")
    frmfmt = re.findall(r"\{\{(\d+),\s*(\d+)\},[^}]*?(OV5647_MODE_\w+)\}", m.group(1))
    return enum, [(int(w), int(h), name) for w, h, name in frmfmt]


def tabele_rejestrow(tbls: str):
    """enum name -> {register: last value written} for its register table."""
    m = re.search(r"mode_table\[\] = \{\n(.*?)\n\};", tbls, re.S)
    if not m:
        blad("no mode_table[] in ov5647_mode_tbls.h")
    przypis = dict(re.findall(r"\[(\w+)\]\s*=\s*(\w+)", m.group(1)))

    out = {}
    for name, tabela in przypis.items():
        t = re.search(r"%s\[\] = \{\n(.*?)\n\};" % re.escape(tabela), tbls, re.S)
        if not t:
            blad("%s names table %s, which does not exist" % (name, tabela))
        regs = {}
        for adr, val in re.findall(r"\{(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\}", t.group(1)):
            regs[int(adr, 16)] = int(val, 16)   # last write wins, as on the wire
        out[name] = regs
    return out


def para(regs, hi, lo):
    """16-bit value split across two registers, None if the table omits it."""
    if hi not in regs or lo not in regs:
        return None                      # table leaves it at the reset default
    return (regs[hi] << 8) | regs[lo]


def czujniki(dts: str):
    """Sensor nodes in file order: (name, [(mode number, {prop: value})]).

    Dual-camera overlays carry one such node per connector, and the modes
    have to line up within a node, not across the file.
    """
    out = []
    for m in re.finditer(r"\n(\t+)(\w*ov5647\w*@[0-9a-f]+) \{(.*?)\n\1\};", dts, re.S):
        tryby = []
        for t in re.finditer(r"\n(\t+)mode(\d+) \{(.*?)\n\1\};", m.group(3), re.S):
            props = dict(re.findall(r'^\s*([a-z_0-9]+) = "([^"]*)";', t.group(3), re.M))
            tryby.append((int(t.group(2)), props))
        if tryby:
            out.append((m.group(2), tryby))
    return out


def main():
    korzen = Path(__file__).resolve().parents[2]
    tbls = (korzen / "driver/ov5647_mode_tbls.h").read_text()
    src = (korzen / "driver/ov5647.c").read_text()

    enum, frmfmt = tryby_sterownika(tbls)
    if len(frmfmt) != len(enum):
        blad("frmfmt[] has %d entries, the mode enum has %d"
             % (len(frmfmt), len(enum)))
    for i, (w, h, name) in enumerate(frmfmt):
        if name != enum[i]:
            blad("frmfmt[%d] is %s where the enum has %s: the table has "
                 "drifted out of enum order" % (i, name, enum[i]))
    print("ok  frmfmt[] lists %d modes, in enum order" % len(frmfmt))

    m = re.search(r"ov5647_min_vts\[\] = \{\n(.*?)\n\};", src, re.S)
    if not m:
        blad("no ov5647_min_vts[] in ov5647.c")
    vts = dict(re.findall(r"\[(\w+)\]\s*=\s*(\d+)", m.group(1)))
    for name in enum:
        if name not in vts:
            blad("%s has no ov5647_min_vts[] entry; a missing one is a "
                 "silent zero and the frame length goes with it" % name)
    print("ok  every mode has a minimum frame length")

    # The register tables are the copy the sensor obeys, so a table that
    # disagrees with frmfmt[] streams one geometry while the framework
    # hands out buffers for another.
    tabele = tabele_rejestrow(tbls)
    for i, (w, h, name) in enumerate(frmfmt):
        regs = tabele.get(name)
        if regs is None:
            blad("%s has no entry in mode_table[]" % name)
        tw = para(regs, 0x3808, 0x3809)
        th = para(regs, 0x380a, 0x380b)
        if tw is None or th is None:
            blad("%s: its register table does not set the output size "
                 "(0x3808-0x380b)" % name)
        if (tw, th) != (w, h):
            blad("%s: the register table programs %dx%d but frmfmt[%d] "
                 "says %dx%d" % (name, tw, th, i, w, h))
    print("ok  every register table programs the output size frmfmt[] "
          "advertises")

    for dts_path in sorted((korzen / "dt").glob("*/*.dts")):
        plyta = dts_path.parent.name
        czujn = czujniki(dts_path.read_text())
        if not czujn:
            blad("%s: no sensor node with modes found" % plyta)
        for nazwa, tryby in czujn:
            sprawdz_czujnik(plyta, nazwa, tryby, frmfmt, tabele)
        print("ok  %-7s %d sensor(s), %d modes each, geometry matches frmfmt[]"
              % (plyta, len(czujn), len(czujn[0][1])))

    print("PASS modes agree between the driver and every overlay")


def sprawdz_czujnik(plyta, nazwa, tryby, frmfmt, tabele):
    plyta = "%s %s" % (plyta, nazwa)
    numery = [n for n, _ in tryby]
    if numery != list(range(len(frmfmt))):
        blad("%s: mode nodes are %s, expected mode0..mode%d in that order"
             % (plyta, numery, len(frmfmt) - 1))

    wzor = set(tryby[0][1])
    for n, props in tryby[1:]:
        if set(props) != wzor:
            brak = wzor - set(props)
            nadto = set(props) - wzor
            blad("%s: mode%d does not carry the same properties as mode0"
                 "%s%s" % (plyta, n,
                           "; missing " + ", ".join(sorted(brak)) if brak else "",
                           "; extra " + ", ".join(sorted(nadto)) if nadto else ""))

    for i, (n, props) in enumerate(tryby):
        w, h, name = frmfmt[i]
        dtw, dth = props.get("active_w"), props.get("active_h")
        if (dtw, dth) != (str(w), str(h)):
            blad("%s: mode%d is %sx%s but frmfmt[%d] (%s) is %dx%d"
                 % (plyta, n, dtw, dth, i, name, w, h))

        # The framework derives frame length from line_length, so a
        # value other than the programmed one skews every exposure.
        hts = para(tabele[name], 0x380c, 0x380d)
        if hts is not None and props.get("line_length") != str(hts):
            blad("%s: mode%d declares line_length %s but %s programs %d"
                 % (plyta, n, props.get("line_length"), name, hts))


if __name__ == "__main__":
    main()
