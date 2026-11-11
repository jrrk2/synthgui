#!/usr/bin/env python3
"""b2cmp.py: second VC707 (no fan, natural convection) against the first, same harness (build C, 66.67 MHz), same X1Y5 window images.
Per path C-R (closing minus opening edge, ps) from base.edges, paired by path number.
Board 1 references (runs/2026-11-09-cool/temperature.txt): cool L2/NS1 (~38.5 C, session A), control L2C (40.3 C) and warm L2W/NS1W (48 C,
session B). Board 2 is compared directly with each, and with board 1 carried to board 2's temperature along board 1's own per-path line:
for l2 through L2C and L2W (one session, so no session offset in the slope); for s1 only NS1 -> NS1W exists (two sessions, slope is an
upper bound). Temperatures for board 2 are the mean of tlog's temp5.csv over each sweep's file times."""
import os, sys, glob
import numpy as np
C = os.path.expanduser('~/synthgui/runs/2026-11-05-char/'); sys.path.insert(0, C); sys.path.insert(0, os.path.expanduser('~/synthgui/runs/2026-11-06-region2'))
os.chdir(C)
from base import edges
import fit64; DD = os.path.join(fit64.D, 'd6/')   # the sweep files live under the NFS root, where edges() reads them
T = np.genfromtxt(C + 'temp5.csv', delimiter=',', skip_header=1)

def temp(pfx):
    f = sorted(glob.glob(DD + pfx + '[0-9]*.txt'), key=os.path.getmtime)
    if not f: return None
    t1 = os.path.getmtime(f[-1]); t0 = os.path.getmtime(f[0]) - (t1 - os.path.getmtime(f[0])) / max(len(f) - 1, 1)
    s = T[(T[:, 0] >= t0) & (T[:, 0] <= t1), 1]
    return (s.mean(), s.min(), s.max()) if len(s) else None

def cr(pfx):
    E = edges('d6/' + pfx); return {p: E[p][1] - E[p][0] for p in E if E[p]}

def stats(a, b, label):
    P = sorted(set(a) & set(b)); d = np.array([b[p] - a[p] for p in P]); x = np.array([a[p] for p in P])
    big = x > 300; ratio = np.median(np.array([b[p] for p in P])[big] / x[big])
    print(f"  {label:34s} {len(P):2d} paths  mean {d.mean():+6.1f}  rms {np.sqrt((d**2).mean()):5.1f}  max |d| {abs(d).max():4.0f} ps"
          f"  median ratio (C-R>300) {ratio:.4f}  mean C-R {x.mean():.0f}")
    return d

REF1 = {'L2R': 36.8, 'L2F': 38.7, 'L2CR': 40.3, 'L2CF': 40.3, 'L2WR': 48.0, 'L2WF': 48.0,
        'NS1R': 38.9, 'NS1F': 39.0, 'NS1WR': 47.9, 'NS1WF': 47.9}
for w, b2, cool, ctl, warm in (('l2', 'B2L2', 'L2', 'L2C', 'L2W'), ('s1', 'B2S1', 'NS1', None, 'NS1W')):
    for e in 'RF':
        t = temp(b2 + e)
        if t is None: print(f"{w} {e}: no board 2 data yet"); continue
        print(f"{w} {'rise' if e == 'R' else 'fall'}: board 2 {b2}{e} at {t[0]:.1f} C ({t[1]:.1f}-{t[2]:.1f})")
        B = cr(b2 + e); refs = [(cool, REF1[cool + e])] + ([(ctl, REF1[ctl + e])] if ctl else []) + [(warm, REF1[warm + e])]
        D = {r: cr(r + e) for r, _ in refs}
        for r, tr in refs: stats(D[r], B, f"board 2 - board 1 {r}{e} ({tr:.1f} C)")
        lo, hi = (ctl, warm) if ctl else (cool, warm); tl, th = REF1[lo + e], REF1[hi + e]
        P = sorted(set(D[lo]) & set(D[hi]))
        X = {p: D[lo][p] + (D[hi][p] - D[lo][p]) * (t[0] - tl) / (th - tl) for p in P}
        stats(X, B, f"board 2 - board 1 at {t[0]:.1f} C (via {lo},{hi})")
