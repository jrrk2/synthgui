#!/usr/bin/env python3
"""Partial reconfiguration images for the open flow.

A window of the device (a rectangle of the prjxray tile grid that covers
whole frame columns of one clock-region row, and ends the row) is built on
its own window chipdb (nextpnr --window) around a static design built with
`-o pr-window`.  Its configuration frames are the only ones that differ, so
they can be rewritten through ICAPE2 while the static design runs.

  merge   harness.fasm window.fasm -> merged.fasm
          The static design's FASM with its window-tile lines replaced by the
          window build's.  Every line of the window build must name a window
          tile (it cannot do otherwise on a window chipdb, this checks it).

  extract merged.frames [--ref harness.frames] -> image
          From the full-device frames of the merged FASM (fasm2frames), the
          window's frame-address row from the window's first frame to the end
          of the row -- the window plus the row's tail columns, which carry
          no CLB -- and the two zero frames that close every row in a 7-series
          stream.  Written as an ICAPE2 word stream: sync, IDCODE, FAR, WCFG,
          FDRI, DESYNC (no CRC: RCRC resets it).  With --ref, the harness's
          own frames are compared: every frame outside the window must be
          identical, and the count of changed window frames is reported.

The window and the tile grid come from the same prjxray database the
chipdb was made from.
"""
import argparse
import collections
import json
import struct
import sys

WORDS_PER_FRAME = 101
ZERO_FRAMES_PER_ROW = 2

# configuration registers and commands, UG470 table 5-23 / 5-24
REG = dict(CRC=0, FAR=1, FDRI=2, FDRO=3, CMD=4, CTL0=5, MASK=6, STAT=7, LOUT=8, COR0=9, MFWR=10, CBC=11,
           IDCODE=12, AXSS=13, COR1=14, WBSTAR=16, TIMER=17, BOOTSTS=22, CTL1=24)
CMD = dict(NULL=0, WCFG=1, MFW=2, LFRM=3, RCFG=4, START=5, RCAP=6, RCRC=7, AGHIGH=8, SWITCH=9, GRESTORE=10,
           SHUTDOWN=11, GCAPTURE=12, DESYNC=13, IPROG=15, CRCC=16, LTIMER=17)


def far_fields(far):
    return dict(block=(far >> 23) & 7, half=(far >> 22) & 1, row=(far >> 17) & 31, column=(far >> 7) & 1023,
                minor=far & 127)


def far_row_key(far):
    f = far_fields(far)
    return (f["block"], f["half"], f["row"])


def load_tilegrid(path):
    with open(path) as f:
        return json.load(f)


def window_tiles(tilegrid, win):
    x0, y0, x1, y1 = win
    return {name: t for name, t in tilegrid.items() if x0 <= t["grid_x"] <= x1 and y0 <= t["grid_y"] <= y1}


def window_frames(tilegrid, win):
    """Every frame address of a window tile, by block type (0: CLB_IO_CLK,
    1: BLOCK_RAM contents), and the one frame-address row they share."""
    fars = collections.defaultdict(set)
    rows = set()
    for name, t in window_tiles(tilegrid, win).items():
        for blk, bits in t.get("bits", {}).items():
            base = int(bits["baseaddr"], 0)
            f = far_fields(base)
            for i in range(bits["frames"]):
                fars[f["block"]].add(base + i)
            rows.add((f["half"], f["row"]))
    if len(rows) != 1:
        sys.exit("window spans %d frame-address rows, it must be one clock-region row: %s" % (len(rows), sorted(rows)))
    return fars, rows.pop()


def column_tiles(tilegrid, row_key):
    """FAR column -> set of tile types with frames in that column of the row."""
    cols = collections.defaultdict(set)
    for name, t in tilegrid.items():
        bits = t.get("bits", {}).get("CLB_IO_CLK")
        if not bits:
            continue
        base = int(bits["baseaddr"], 0)
        if far_row_key(base) == row_key:
            cols[far_fields(base)["column"]].add(t["type"])
    return cols


def read_frames(path):
    frames = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            addr, data = line.split(" ", 1)
            words = [int(w, 0) for w in data.split(",")]
            if len(words) != WORDS_PER_FRAME:
                sys.exit("%s: frame %s has %d words" % (path, addr, len(words)))
            frames[int(addr, 0)] = words
    return frames


def tile_of_line(line):
    return line.split(".", 1)[0].strip()


def cmd_merge(args):
    tilegrid = load_tilegrid(args.tilegrid)
    win = [int(v) for v in args.window.split(",")]
    inside = set(window_tiles(tilegrid, win))
    out = []
    dropped = 0
    with open(args.harness) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if tile_of_line(s) in inside:
                dropped += 1
                continue
            out.append(s)
    added = 0
    with open(args.window_fasm) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tile = tile_of_line(s)
            if tile not in inside:
                if tile not in tilegrid:
                    sys.exit("window FASM names unknown tile %s" % tile)
                sys.exit("window FASM line is outside the window: %s" % s)
            out.append(s)
            added += 1
    with open(args.out, "w") as f:
        f.write("\n".join(out) + "\n")
    print("merge: %d harness lines in the window dropped, %d window lines added, %d lines written" %
          (dropped, added, len(out)))


def icap_words(blocks, idcode):
    """blocks: list of (first FAR, [words])."""
    def type1(opcode, reg, count):
        return (1 << 29) | (opcode << 27) | (reg << 13) | count

    def type2(opcode, count):
        return (2 << 29) | (opcode << 27) | count

    W, NOP = 2, 0
    words = [0xFFFFFFFF] * 8 + [0x000000BB, 0x11220044] + [0xFFFFFFFF] * 2 + [0xAA995566]
    words += [type1(NOP, 0, 0)]
    words += [type1(W, REG["CMD"], 1), CMD["RCRC"], type1(NOP, 0, 0), type1(NOP, 0, 0)]
    words += [type1(W, REG["IDCODE"], 1), idcode, type1(NOP, 0, 0)]
    for far, data in blocks:
        words += [type1(W, REG["FAR"], 1), far]
        words += [type1(W, REG["CMD"], 1), CMD["WCFG"], type1(NOP, 0, 0)]
        words += [type1(W, REG["FDRI"], 0), type2(W, len(data))]
        words += data
        words += [type1(NOP, 0, 0)]
    words += [type1(W, REG["CMD"], 1), CMD["RCRC"], type1(NOP, 0, 0), type1(NOP, 0, 0)]
    words += [type1(W, REG["CMD"], 1), CMD["DESYNC"]] + [type1(NOP, 0, 0)] * 4
    return words


def cmd_extract(args):
    tilegrid = load_tilegrid(args.tilegrid)
    win = [int(v) for v in args.window.split(",")]
    wfars_by_type, (half, row) = window_frames(tilegrid, win)
    frames = read_frames(args.frames)
    ref = read_frames(args.ref) if args.ref else None
    all_wfars = set().union(*wfars_by_type.values())
    missing = [f for f in all_wfars if f not in frames]
    if missing:
        sys.exit("%d window frames are not in %s (first 0x%08x)" % (len(missing), args.frames, min(missing)))
    if ref is not None:
        outside_diff = [f for f in frames if f not in all_wfars and frames[f] != ref.get(f)]
        if outside_diff:
            sys.exit("%d frames differ OUTSIDE the window (first 0x%08x): the static design changed, the image "
                     "would not be partial" % (len(outside_diff), min(outside_diff)))
    blocks = []
    report = []
    for blk in sorted(wfars_by_type):
        wfars = wfars_by_type[blk]
        changed = sum(1 for f in wfars if frames[f] != ref.get(f)) if ref is not None else None
        # block type 0 is always written; a block RAM contents block only when it changed
        if blk != 0 and changed == 0:
            report.append("block type %d: %d window frames unchanged, not written" % (blk, len(wfars)))
            continue
        row_key = (blk, half, row)
        first = min(wfars)
        rowf = sorted(f for f in frames if far_row_key(f) == row_key and f >= first)
        wcols = {far_fields(f)["column"] for f in wfars}
        tail_cols = sorted({far_fields(f)["column"] for f in rowf} - wcols)
        cols = column_tiles(tilegrid, row_key)
        for c in tail_cols:
            clb = [t for t in cols[c] if t.startswith("CLB")]
            if clb:
                sys.exit("tail column %d (after the window, before the row end) holds CLB tiles %s: a window must "
                         "end its row's CLB columns" % (c, clb))
            if blk != 0:
                sys.exit("tail column %d of block type %d: the window must end its row's block RAM columns" % (c, blk))
        if ref is not None:
            tail_diff = [f for f in rowf if f not in wfars and frames[f] != ref.get(f)]
            if tail_diff:
                sys.exit("internal: tail frames differ")
        data = []
        for f in rowf:
            data += frames[f]
        data += [0] * (WORDS_PER_FRAME * ZERO_FRAMES_PER_ROW)
        blocks.append((first, data))
        report.append("block type %d: window %d frames in columns %d..%d, image from 0x%08x: %d frames + %d zero "
                      "frames, tail columns %s%s" % (blk, len(wfars), min(wcols), max(wcols), first, len(rowf),
                                                     ZERO_FRAMES_PER_ROW, tail_cols,
                                                     "" if changed is None else ", %d frames changed" % changed))
        if args.frames_out:
            with open(args.frames_out if blk == 0 else args.frames_out + ".type%d" % blk, "w") as f:
                for far in rowf:
                    f.write("0x%08x %s\n" % (far, ",".join("0x%08x" % w for w in frames[far])))
    words = icap_words(blocks, int(args.idcode, 0))
    with open(args.out, "wb") as f:
        f.write(struct.pack(">%dI" % len(words), *words))
    print("extract: window %s, frame row half %d row %d" % (args.window, half, row))
    for r in report:
        print("  " + r)
    print("  %d words (%d bytes) -> %s%s" % (len(words), 4 * len(words), args.out,
                                             "; no frame outside the window differs from the reference" if ref else ""))


def cmd_check(args):
    """Two drivers on one wire of the merged design.  Across tiles only the nodes
    in the window map are known, which is every node that crosses the window's
    edge, the only ones a harness and a window can both drive; nodes wholly inside
    the window are checked by tile and wire alone."""
    wires = json.load(open(args.map))["wires"]
    drivers = {}
    pips = 0
    with open(args.merged) as f:
        for line in f:
            s = line.strip()
            parts = s.split(".")
            if len(parts) != 3:
                continue
            key = parts[0] + "/" + parts[1]
            canon = wires.get(key)
            if canon is not None:
                drivers.setdefault(canon, set()).add(s)
            elif parts[0].startswith("INT_"):
                drivers.setdefault(key, set()).add(s)
            else:
                continue
            pips += 1
    bad = 0
    for k in sorted(drivers):
        if len(drivers[k]) > 1:
            bad += 1
            print("  %s: %s" % (k, ", ".join(sorted(drivers[k]))))
    print("check: %d pips onto %d wires, %d with two or more drivers" % (pips, len(drivers), bad))
    if bad:
        sys.exit("pr_partial: a node has two drivers: this design has a short, no image")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "check":
        p = argparse.ArgumentParser(description="pr_partial.py check merged.fasm --map window-map.json")
        p.add_argument("cmd")
        p.add_argument("merged")
        p.add_argument("--map", required=True)
        cmd_check(p.parse_args())
        return
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tilegrid", required=True, help="prjxray tilegrid.json of the device")
    p.add_argument("--window", required=True, help="x0,y0,x1,y1 tile grid rectangle, as given to the chipdb generator")
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("harness")
    m.add_argument("window_fasm")
    m.add_argument("out")
    e = sub.add_parser("extract")
    e.add_argument("frames", help="fasm2frames output of the merged FASM")
    e.add_argument("out", help="ICAPE2 word stream, big-endian 32-bit words")
    e.add_argument("--ref", help="frames of the harness alone, to prove the image only touches the window")
    e.add_argument("--idcode", default="0x03687093", help="device IDCODE (xc7vx485t default)")
    e.add_argument("--frames-out", help="also write the image's frames in fasm2frames' text format")
    args = p.parse_args()
    if args.cmd == "merge":
        cmd_merge(args)
    else:
        cmd_extract(args)


if __name__ == "__main__":
    main()
