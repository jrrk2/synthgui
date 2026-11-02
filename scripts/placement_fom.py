#!/usr/bin/env python3
"""Placement figures of merit, to be ranked against routing outcomes.

fom.py --json NETLIST.json --sites sites.txt LABEL=(nextpnr:PLACED.json | vivado:cells_grid.txt) ...

Candidates, all computed from the placement alone (Vivado's tile grid):
  hpwl      sum of net half-perimeters, x counted double (HeAP's weighting)
  work      sum over arcs (driver->sink) of the search box area (|dx|+4)*(|dy|+4)*2:
            router2 explores a box per arc, so this approximates a pass's search
  long      nets spanning more than 150 units, and their pins
  centre    nets crossing both pin-median lines: routed single-threaded by router2
  demand    RUDY demand per occupied tile: median, p99, and the share of pins
            sitting in tiles above 300 (an absolute level, same units everywhere)
  window    peak 16x16-window demand over the median window
  slices    occupied tiles
"""
import argparse, collections, json, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('--json', required=True)
ap.add_argument('--sites', required=True)
ap.add_argument('placements', nargs='+')
a = ap.parse_args()

site_xy = {}
for line in open(a.sites):
    f = line.rstrip('\n').split('\t')
    if len(f) >= 4:
        site_xy[f[0]] = (int(f[2]), int(f[3]))
W = max(x for x, y in site_xy.values()) + 1
H = max(y for x, y in site_xy.values()) + 1

d = json.load(open(a.json))
mod = d['modules'][list(d['modules'])[0]]
cells = mod['cells']
pins = collections.defaultdict(list)   # bit -> [(cell, is_driver)]
for cn, c in cells.items():
    dirs = c.get('port_directions', {})
    for p, bits in c['connections'].items():
        drv = dirs.get(p, 'input') == 'output'
        for b in bits:
            if isinstance(b, int):
                pins[b].append((cn, drv))

def load(spec):
    kind, path = spec.split(':', 1)
    pos = {}
    if kind == 'nextpnr':
        pm = json.load(open(path))['modules']
        pm = pm[list(pm)[0]]['cells']
        for cn, c in pm.items():
            bel = c.get('attributes', {}).get('NEXTPNR_BEL')
            if not bel:
                continue
            m = re.match(r'X(\d+)Y(\d+)/', bel)
            if m:
                pos[cn] = (int(m.group(1)), int(m.group(2)))
            elif bel.split('/')[0] in site_xy:
                pos[cn] = site_xy[bel.split('/')[0]]
    else:
        for line in open(path):
            f = line.rstrip('\n').split('\t')
            if len(f) >= 7 and f[5] != '':
                pos[f[0]] = (int(f[5]), int(f[6]))
    return pos

def pct(v, p): return v[min(len(v) - 1, int(p * len(v)))]

print('%-14s %9s %12s %7s %8s %7s %8s %6s %6s %6s %6s %7s' % ('placement', 'hpwl', 'work', 'long', 'longpins', 'centre', 'cpins', 'dmed', 'dp99', 'hot%', 'window', 'slices'))
for spec in a.placements:
    label, rest = spec.split('=', 1)
    pos = load(rest)
    hpwl = 0; work = 0; long_n = 0; long_p = 0
    bbs = []
    for b, pl in pins.items():
        pts = [(pos[cn], drv) for cn, drv in pl if cn in pos]
        if len(pts) < 2:
            continue
        if len(pl) > 1000:   # clocks and resets: global resources
            continue
        xs = [p[0][0] for p in pts]; ys = [p[0][1] for p in pts]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        span = 2 * (x1 - x0) + (y1 - y0)
        hpwl += span
        bbs.append((x0, y0, x1, y1, len(pts)))
        if span > 150:
            long_n += 1; long_p += len(pts)
        drv = [p[0] for p in pts if p[1]]
        if drv:
            dx0, dy0 = drv[0]
            for (sx, sy), isd in pts:
                if not isd:
                    work += 2 * (abs(sx - dx0) + 4) * (abs(sy - dy0) + 4)
    # router2's split: pin medians
    xs = collections.Counter(); ys = collections.Counter()
    for x0, y0, x1, y1, n in bbs:
        xs[x0] += n; xs[x1] += n; ys[y0] += n; ys[y1] += n
    def half(cnt):
        tot = sum(cnt.values()); acc = 0
        for k in sorted(cnt):
            acc += cnt[k]
            if acc * 2 >= tot:
                return k
    mx, my = half(xs), half(ys)
    centre = 0; cpins = 0
    for x0, y0, x1, y1, n in bbs:
        if x0 < mx <= x1 and y0 < my <= y1:
            centre += 1; cpins += n
    # RUDY
    rudy = [[0.0] * H for _ in range(W)]
    for x0, y0, x1, y1, n in bbs:
        w = x1 - x0 + 1; h = y1 - y0 + 1
        dem = (w + h) / (w * h) * max(1, n - 1) ** 0.5
        for x in range(x0, x1 + 1):
            col = rudy[x]
            for y in range(y0, y1 + 1):
                col[y] += dem
    occ = collections.Counter(pos.values())
    vals = sorted(rudy[x][y] for (x, y) in occ)
    hot_pins = sum(c for (x, y), c in occ.items() if rudy[x][y] > 300)
    tot_pins = sum(occ.values())
    # overflow above several levels, per cell placed (so dense and spread placements compare)
    over = {}
    for lvl in (200, 250, 300, 350):
        over[lvl] = sum(max(0.0, rudy[x][y] - lvl) * c for (x, y), c in occ.items()) / tot_pins
    cell_weighted = sum(rudy[x][y] * c for (x, y), c in occ.items()) / tot_pins
    win = 16; wins = []
    for wx in range(0, W, 8):
        for wy in range(0, H, 8):
            s = 0.0
            for x in range(wx, min(W, wx + win)):
                for y in range(wy, min(H, wy + win)):
                    s += rudy[x][y]
            if s > 0:
                wins.append(s)
    wins.sort()
    window = wins[-1] / pct(wins, 0.5) if wins else 0
    print('%-14s %9d %12d %7d %8d %7d %8d %6.0f %6.0f %6.1f %6.1f %7d  cellwt %5.0f  over200 %5.1f over250 %5.1f over300 %5.1f over350 %5.1f' % (
        label, hpwl, work, long_n, long_p, centre, cpins, pct(vals, 0.5), pct(vals, 0.99),
        100.0 * hot_pins / tot_pins, window, len(occ), cell_weighted, over[200], over[250], over[300], over[350]))
