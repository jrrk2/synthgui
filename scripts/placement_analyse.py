#!/usr/bin/env python3
"""Placement congestion analysis for a nextpnr netlist json.

analyse.py --json NETLIST.json --sites sites.txt (--nextpnr PLACED.json | --vivado cells_grid.txt) [--label L]

Both placements are put in the Vivado tile grid (COLUMN, ROW), which is the
prjxray tilegrid frame nextpnr's himbaechel-xilinx uses for its X/Y.
"""
import argparse, collections, json, math, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('--json', required=True)
ap.add_argument('--sites', required=True)
ap.add_argument('--nextpnr')
ap.add_argument('--vivado')
ap.add_argument('--label', default='')
ap.add_argument('--bigpins', type=int, default=1000, help='nets with more sinks are globals: excluded from RUDY')
ap.add_argument('--heat', action='store_true', help='print an ASCII heat map')
a = ap.parse_args()

# ---------------------------------------------------------------- site grid
site_xy = {}
for line in open(a.sites):
    f = line.rstrip('\n').split('\t')
    if len(f) < 4:
        continue
    site_xy[f[0]] = (int(f[2]), int(f[3]))

# ---------------------------------------------------------------- netlist
d = json.load(open(a.json))
mod = d['modules'][list(d['modules'])[0]]
cells = mod['cells']
pins = collections.defaultdict(list)   # bit -> [(cell, port, dir)]
for cn, c in cells.items():
    dirs = c.get('port_directions', {})
    for p, bits in c['connections'].items():
        dr = dirs.get(p, 'input')
        for b in bits:
            if isinstance(b, int):
                pins[b].append((cn, p, dr))

# ---------------------------------------------------------------- placement
pos = {}
if a.nextpnr:
    pd = json.load(open(a.nextpnr))
    pm = pd['modules'][list(pd['modules'])[0]]['cells']
    unk = 0
    for cn, c in pm.items():
        bel = c.get('attributes', {}).get('NEXTPNR_BEL')
        if not bel:
            continue
        m = re.match(r'X(\d+)Y(\d+)/', bel)   # tile form, as --write gives before routing
        site = bel.split('/')[0]
        if m:
            pos[cn] = (int(m.group(1)), int(m.group(2)))
        elif site in site_xy:
            pos[cn] = site_xy[site]
        else:
            unk += 1
    if unk:
        print(f'# {unk} nextpnr cells on sites missing from the site table')
elif a.vivado:
    for line in open(a.vivado):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 7 and f[5] != '':
            pos[f[0]] = (int(f[5]), int(f[6]))
else:
    sys.exit('need --nextpnr or --vivado')

placed_netlist = [cn for cn in cells if cn in pos]
print(f'== {a.label}: {len(cells)} netlist cells, {len(pos)} placed, {len(placed_netlist)} matched by name')

LANE = re.compile(r'u_core_i_hh_gen_lane_(\d)__')
def lane_of(cn):
    m = LANE.search(cn)
    return int(m.group(1)) if m else -1

# ---------------------------------------------------------------- nets
nets = []   # (bit, [(x,y)...], nsinks, driver cell)
for b, pl in pins.items():
    pts = []
    drv = None
    for cn, p, dr in pl:
        if cn in pos:
            pts.append(pos[cn])
        if dr == 'output':
            drv = cn
    if len(pts) >= 2:
        nets.append((b, pts, len(pl) - 1, drv))
print(f'{len(nets)} nets with >=2 placed pins')

def bbox(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)

hpwl = 0
bbs = []
big = []
for b, pts, ns, drv in nets:
    x0, y0, x1, y1 = bbox(pts)
    hpwl += (x1 - x0) + (y1 - y0)
    if ns > a.bigpins:
        big.append((ns, drv, (x0, y0, x1, y1)))
    else:
        bbs.append((x0, y0, x1, y1, len(pts)))
print(f'HPWL {hpwl} (grid units); {len(big)} global nets excluded:',
      ', '.join(f'{drv}({ns})' for ns, drv, _ in sorted(big, reverse=True)[:6]))
spans = sorted((x1 - x0) + (y1 - y0) for x0, y0, x1, y1, n in bbs)
def pct(v, p): return v[min(len(v) - 1, int(p * len(v)))]
print(f'net span: median {pct(spans,0.5)} p90 {pct(spans,0.9)} p99 {pct(spans,0.99)} max {spans[-1]}')

# ---------------------------------------------------------------- router2 partition
# router2 picks mid_x/mid_y where half the net pins lie, then bins nets by whether
# their bbox clears the split line.
xs = collections.Counter(); ys = collections.Counter()
for x0, y0, x1, y1, n in bbs:
    xs[x0] += n; xs[x1] += n; ys[y0] += n; ys[y1] += n
def halfway(cnt):
    tot = sum(cnt.values()); acc = 0
    for k in sorted(cnt):
        acc += cnt[k]
        if acc >= tot / 2:
            return k
mx, my = halfway(xs), halfway(ys)
bins = collections.Counter(); bpins = collections.Counter()
for x0, y0, x1, y1, n in bbs:
    lx = x1 < mx; rx = x0 >= mx; ty = y1 < my; by = y0 >= my
    if (lx or rx) and (ty or by): k = 'quadrant'
    elif ty or by: k = 'half-V'
    elif lx or rx: k = 'half-H'
    else: k = 'serial'
    bins[k] += 1; bpins[k] += n
print(f'router2 split at x={mx} y={my}: ' + '  '.join(f'{k} {bins[k]} nets/{bpins[k]} pins' for k in ('quadrant', 'half-V', 'half-H', 'serial')))

# ---------------------------------------------------------------- RUDY map
W = max(x for x, y in site_xy.values()) + 1
H = max(y for x, y in site_xy.values()) + 1
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
med = pct(vals, 0.5)
peak = max(vals)
hot = sum(1 for v in vals if v > 2 * med)
print(f'RUDY over {len(vals)} occupied tiles: median {med:.1f} p90 {pct(vals,0.9):.1f} p99 {pct(vals,0.99):.1f} peak {peak:.1f} ({peak/med:.1f}x median); {hot} tiles >2x median')

# hottest 16x16 windows with lane make-up
win = 16
wins = []
for wx in range(0, W, win // 2):
    for wy in range(0, H, win // 2):
        s = 0.0; m = 0.0
        for x in range(wx, min(W, wx + win)):
            for y in range(wy, min(H, wy + win)):
                v = rudy[x][y]; s += v; m = max(m, v)
        wins.append((s, m, wx, wy))
wins.sort(reverse=True)
print('hottest windows (sum, max, x, y, cells, lanes):')
for s, m, wx, wy in wins[:6]:
    lc = collections.Counter()
    for cn in placed_netlist:
        x, y = pos[cn]
        if wx <= x < wx + win and wy <= y < wy + win:
            lc[lane_of(cn)] += 1
    print(f'  {s:9.0f} {m:7.1f} X{wx:3d} Y{wy:3d} cells {sum(lc.values()):5d} ' +
          ' '.join(f'L{l}:{c}' if l >= 0 else f'other:{c}' for l, c in sorted(lc.items())))

if a.heat:
    sx = max(1, W // 60); sy = max(1, H // 40)
    ramp = ' .:-=+*#%@'
    print(f'heat map ({sx}x{sy} tiles per char, scale: peak of each block / {med*4:.0f})')
    for by in range(0, H, sy):
        row = ''
        for bx in range(0, W, sx):
            m = 0.0
            for x in range(bx, min(W, bx + sx)):
                for y in range(by, min(H, by + sy)):
                    m = max(m, rudy[x][y])
            row += ramp[min(9, int(m / (med * 4) * 9))] if med > 0 else ' '
        print(row)

# ---------------------------------------------------------------- columns
# mean demand per tile column, with what the column is made of
col_kind = {}
for line in open(a.sites):
    f = line.rstrip('\n').split('\t')
    if len(f) >= 5:
        k = f[4]
        if k.startswith('SLICE'): k = 'CLB'
        elif k.startswith('DSP'): k = 'DSP'
        elif k.startswith('RAMB') or k.startswith('FIFO'): k = 'BRAM'
        col_kind.setdefault(int(f[2]), collections.Counter())[k] += 1
cols = collections.defaultdict(list)
for (x, y) in occ:
    cols[x].append(rudy[x][y])
rows = []
for x, v in cols.items():
    kind = col_kind.get(x, collections.Counter()).most_common(1)
    rows.append((sum(v) / len(v), x, len(v), kind[0][0] if kind else '-'))
rows.sort(reverse=True)
print('hottest columns (mean demand, x, occupied tiles, kind):', ' '.join(f'{m:.0f}@X{x}({n},{k})' for m, x, n, k in rows[:12]))
byk = collections.defaultdict(list)
for m, x, n, k in rows:
    byk[k].append(m)
print('mean column demand by kind:', ' '.join(f'{k}:{sum(v)/len(v):.0f}' for k, v in byk.items()))

# ---------------------------------------------------------------- lanes
print('lanes (cells, centroid, 10..90% box):')
for ln in range(-1, 4):
    pts = [pos[cn] for cn in placed_netlist if lane_of(cn) == ln]
    if not pts:
        continue
    xs_ = sorted(p[0] for p in pts); ys_ = sorted(p[1] for p in pts)
    print(f'  {"other" if ln < 0 else "lane"+str(ln)}: {len(pts):6d} cells  centroid ({sum(xs_)/len(xs_):.0f},{sum(ys_)/len(ys_):.0f})  '
          f'x {pct(xs_,0.1)}..{pct(xs_,0.9)}  y {pct(ys_,0.1)}..{pct(ys_,0.9)}')

# ---------------------------------------------------------------- DSPs
dsps = [cn for cn, c in cells.items() if c['type'] == 'DSP48E1' and cn in pos]
print(f'DSP48E1: {len(dsps)} placed')
drv_of = {}
for b, pl in pins.items():
    for cn, p, dr in pl:
        if dr == 'output':
            drv_of[b] = cn
sinks_of = collections.defaultdict(list)
for b, pl in pins.items():
    for cn, p, dr in pl:
        if dr != 'output':
            sinks_of[b].append(cn)
per_lane = collections.defaultdict(list)
for cn in dsps:
    c = cells[cn]
    x, y = pos[cn]
    din = []; dout = []; lanes = collections.Counter()
    for p, bits in c['connections'].items():
        if p in ('A', 'B', 'C', 'D'):
            for b in bits:
                if isinstance(b, int) and b in drv_of and drv_of[b] in pos:
                    din.append(pos[drv_of[b]]); lanes[lane_of(drv_of[b])] += 1
        elif p == 'P':
            for b in bits:
                if isinstance(b, int):
                    for s in sinks_of.get(b, []):
                        if s in pos:
                            dout.append(pos[s]); lanes[lane_of(s)] += 1
    ln = lanes.most_common(1)[0][0] if lanes else -1
    md = lambda pts: sum(abs(px - x) + abs(py - y) for px, py in pts) / len(pts) if pts else float('nan')
    per_lane[ln].append((cn, x, y, md(din), md(dout), len(din), len(dout)))
for ln in sorted(per_lane):
    L = per_lane[ln]
    cols = collections.Counter(x for _, x, y, *_ in L)
    ys_ = [y for _, x, y, *_ in L]
    print(f'  lane{ln}: {len(L)} DSPs in {len(cols)} columns {dict(sorted(cols.items()))}  y {min(ys_)}..{max(ys_)}  '
          f'mean |fan-in| {sum(t[3] for t in L)/len(L):.1f}  mean |fan-out| {sum(t[4] for t in L)/len(L):.1f} tiles')
