#!/usr/bin/env python3
"""at_sweep.py [--port P] [--paths N] [--cycles C] [--mult 6 --div 1 --odiv 12] [--cdelay 0-4] out.csv
Capture-phase sweep over the BIOS console: for each (cdelay, cmux) step the capture clock's phase by
(cmux/8 + cdelay) VCO periods with `tmmcm`, run the block, read the counters, decode the LFSR states."""
import argparse, re, subprocess, sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from at_gen import lfsr16_decode
p = argparse.ArgumentParser()
p.add_argument("--port", default="/dev/ttyUSB0"); p.add_argument("--paths", type=int, default=5)
p.add_argument("--cycles", type=int, default=50000); p.add_argument("--mult", type=int, default=6)
p.add_argument("--div", type=int, default=1); p.add_argument("--odiv", type=int, default=12)
p.add_argument("--cdelay", default="0-4"); p.add_argument("--cmux", default="0-7"); p.add_argument("out")
a = p.parse_args()
dec = lfsr16_decode()
def rng(s):
    lo, hi = (s.split("-") + [s])[:2]; return range(int(lo), int(hi) + 1)
vco_ps = 1e6 / (200.0 * a.mult / a.div)      # VCO period in ps from the 200 MHz input
bios = [sys.executable, __file__.rsplit("/", 1)[0] + "/bios_cmd.py", "--port", a.port, "--wait", "15"]
rows = []
with open(a.out, "w") as f:
    f.write("cdelay,cmux,offset_ps," + ",".join("path%d" % i for i in range(a.paths)) + "\n")
    for cd in rng(a.cdelay):
        for cm in rng(a.cmux):
            out = subprocess.run(bios + ["tmmcm %d %d %d %d %d" % (a.mult, a.div, a.odiv, cm, cd), "at %d" % a.cycles,
                                 "atread %d" % a.paths], capture_output=True, text=True).stdout
            vals = [int(v) for v in re.findall(r"path \d+: (\d+) errors", out)]
            counts = [dec.get(v, -1) for v in vals]
            off = (cm / 8.0 + cd) * vco_ps
            f.write("%d,%d,%.0f,%s\n" % (cd, cm, off, ",".join(str(c) for c in counts))); f.flush()
            print("cdelay %d cmux %d  offset %6.0f ps  %s" % (cd, cm, off, " ".join("%6d" % c for c in counts)), flush=True)
            if len(vals) != a.paths:
                print("   (unexpected console output: %r)" % out[-300:])
