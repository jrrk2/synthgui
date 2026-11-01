#!/usr/bin/env python3
"""mmcm_retime.py -- set an MMCM output's frequency in a routed design's FASM,
from the frequency the routed design actually achieves, without placing or
routing again.

  mmcm_retime.py --fasm IN.fasm --out OUT.fasm --routed ROUTED.json \\
                 --placement PLACEMENT.json --cell clkgen_mmcm --output CLKOUT1 \\
                 ( --divide N | --pnr-log pnr.log --clock clk_mac [--margin 0.10] [--max-mhz F] )

Only an output divider changes.  The VCO (CLKIN, CLKFBOUT_MULT_F, DIVCLK_DIVIDE),
and with it the MMCM's lock and loop-filter settings, stay as nextpnr wrote
them, and so does every placed cell and routed net: the design's paths are
the ones nextpnr timed, at a different period.  A slower clock cannot fail
setup on a path that passed at the faster one, and hold does not depend on
the period, so lowering a clock is always safe; raising it is safe up to the
Fmax nextpnr reported, less the margin (nextpnr's delay model is an estimate).
Paths between this clock and another one are not re-checked: in the designs
this is for they are asynchronous (synchronisers, async FIFOs).

The divider is chosen as the smallest integer D with VCO/D <= Fmax*(1-margin)
(and <= --max-mhz if given).  The output's counter is rewritten the way
nextpnr's FASM writer programs an integer divide at 50 % duty and 0 phase
(Xilinx XAPP888): HIGH_TIME = D/2, LOW_TIME = D - D/2 (6-bit fields, a count
of 64 written 0), EDGE = D odd, NO_COUNT = D == 1 -- checked against nextpnr's
own output for D = 2..128.  Fractional dividers (CLKOUT0/CLKFBOUT _F), other duty
cycles and phase shifts are refused rather than guessed at.  Before writing,
the tool checks that the counter it finds in the FASM is the one the
current divider gives -- that it is patching the right tile and output.

The output's frequency is printed; regenerate the frames and bitstream from
OUT.fasm as usual (fasm2frames, xc7frames2bit).
"""
import argparse
import json
import math
import re
import sys


def die(msg):
    sys.exit(f"mmcm_retime: {msg}")


def param(cell, name, default=None):
    v = cell.get("parameters", {}).get(name)
    if v is None:
        return default
    if isinstance(v, str) and re.fullmatch(r"[01]{32}", v):
        return int(v, 2)  # yosys-JSON integer parameter
    try:
        return float(v)
    except (TypeError, ValueError):
        return v


def counter(d):
    """HIGH_TIME, LOW_TIME, EDGE, NO_COUNT of an integer divide at 50 % duty, 0 phase, as the
    6-bit fields hold them: a count of 64 (divide 127 or 128) is written 0."""
    high = d // 2
    return high & 63, (d - high) & 63, d & 1, int(d == 1)


def final_fmax(log_path, clock):
    """The last 'Max frequency for clock' report of a clock (nextpnr prints one before routing, one after)."""
    last = None
    pat = re.compile(r"Max frequency for clock\s+'([^']+)':\s+([0-9.]+) MHz")
    for line in open(log_path, errors="replace"):
        m = pat.search(line)
        if m and m.group(1) == clock:
            last = float(m.group(2))
    if last is None:
        die(f"no 'Max frequency for clock '{clock}'' in {log_path}")
    return last


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fasm", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--routed", required=True, help="nextpnr --write output (the MMCM's parameters)")
    ap.add_argument("--placement", required=True, help="nextpnr -o placement= output (the MMCM's tile)")
    ap.add_argument("--cell", required=True, help="the MMCME2_ADV cell, e.g. clkgen_mmcm")
    ap.add_argument("--output", default="CLKOUT1", help="CLKOUT0..CLKOUT6")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--divide", type=int, help="the new integer divider")
    g.add_argument("--pnr-log", help="nextpnr log: take this clock's achieved Fmax from its last report")
    ap.add_argument("--clock", help="the clock's name in the nextpnr log (with --pnr-log)")
    ap.add_argument("--margin", type=float, default=0.10, help="fraction of Fmax held back (default 0.10)")
    ap.add_argument("--max-mhz", type=float, help="never faster than this")
    a = ap.parse_args()
    out = a.output.upper()
    if not re.fullmatch(r"CLKOUT[0-6]", out):
        die(f"--output must be CLKOUT0..CLKOUT6, not {a.output}")

    mod = next(iter(json.load(open(a.routed))["modules"].values()))
    cell = mod["cells"].get(a.cell)
    if cell is None or not cell["type"].startswith("MMCME2_ADV"):
        die(f"no MMCME2_ADV cell '{a.cell}' in {a.routed}")
    period = param(cell, "CLKIN1_PERIOD")
    mult = param(cell, "CLKFBOUT_MULT_F", 5.0)
    divclk = param(cell, "DIVCLK_DIVIDE", 1)
    if not period:
        die(f"{a.cell} has no CLKIN1_PERIOD")
    vco = 1000.0 / float(period) * float(mult) / float(divclk)
    dname = f"{out}_DIVIDE_F" if out == "CLKOUT0" else f"{out}_DIVIDE"
    cur = param(cell, dname, 1)
    phase = param(cell, f"{out}_PHASE", 0.0)
    duty = param(cell, f"{out}_DUTY_CYCLE", 0.5)
    if float(cur) != int(cur):
        die(f"{a.cell}.{dname} = {cur} is fractional; only integer dividers are rewritten")
    if float(phase) != 0.0 or float(duty) != 0.5:
        die(f"{a.cell}.{out} has PHASE {phase} / DUTY_CYCLE {duty}; only 0 / 0.5 are rewritten")
    cur = int(cur)

    if a.divide is not None:
        new = a.divide
        why = "as asked"
    else:
        if not a.clock:
            die("--pnr-log needs --clock")
        fmax = final_fmax(a.pnr_log, a.clock)
        target = fmax * (1.0 - a.margin)
        if a.max_mhz:
            target = min(target, a.max_mhz)
        new = max(1, math.ceil(vco / target - 1e-9))
        why = f"{a.clock} achieved {fmax:.2f} MHz, {a.margin:.0%} margin -> at most {target:.2f} MHz"
    if not 1 <= new <= 128:
        die(f"divider {new} outside 1..128")

    pl = json.load(open(a.placement)).get(a.cell)
    if not pl or "tile" not in pl:
        die(f"'{a.cell}' not in {a.placement}")
    tile = pl["tile"]
    pre = f"{tile}.MMCME2_ADV.{out}_"
    feats = {
        "HIGH": f"{pre}CLKOUT1_HIGH_TIME[5:0]",
        "LOW": f"{pre}CLKOUT1_LOW_TIME[5:0]",
        "EDGE": f"{pre}CLKOUT2_EDGE[0]",
        "NOCOUNT": f"{pre}CLKOUT2_NO_COUNT[0]",
    }

    lines = open(a.fasm).read().splitlines()
    found = {}
    for i, l in enumerate(lines):
        for k, f in feats.items():
            if l.startswith(f):
                m = re.search(r"= *\d+'b([01]+)", l)
                found[k] = (i, int(m.group(1), 2) if m else 1)
    if "HIGH" not in found or "LOW" not in found:
        die(f"no {out} counter for tile {tile} in {a.fasm} (is {a.output} used?)")
    have = (found["HIGH"][1], found["LOW"][1], found.get("EDGE", (0, 0))[1], found.get("NOCOUNT", (0, 0))[1])
    if have != counter(cur):
        die(f"{tile} {out} counter in the FASM is {have}, not {counter(cur)} for divide {cur}: wrong tile or output?")

    high, low, edge, nocount = counter(new)
    drop = {found[k][0] for k in found}
    kept = [l for i, l in enumerate(lines) if i not in drop]
    kept.append(f"{feats['HIGH']} = 6'b{high:06b}")
    kept.append(f"{feats['LOW']} = 6'b{low:06b}")
    if edge:
        kept.append(feats["EDGE"])
    if nocount:
        kept.append(feats["NOCOUNT"])
    open(a.out, "w").write("\n".join(kept) + "\n")
    print(f"mmcm_retime: {a.cell} ({tile}) {out}: divide {cur} -> {new}, "
          f"{vco / cur:.3f} -> {vco / new:.3f} MHz (VCO {vco:.1f} MHz; {why})")


if __name__ == "__main__":
    main()
