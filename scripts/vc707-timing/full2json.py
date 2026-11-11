#!/usr/bin/env python3
"""full2json.py <routed.json> <harness.fasm> <out.json>: a full-device routed JSON (himbaechel dialect: pips 'X<col>Y<row>/dst/src',
sites relative to their tile) in the dialect json2dcp reads (full tile names, 'src->dst', device site names). Generalises
runs/2026-11-07-dcp/win2json.py (window offsets, SLICE sites only) to the whole device and every site type.

No cell or route changes. Checks the result against the FASM: every INT pip here is in the FASM and the reverse, except prjxray's
bitless always-on pips. Exit 1 if they differ."""
import json, os, re, sys, collections
H = os.path.expanduser('~'); TG = H + '/synthgui/deps/prjxray-db/virtex7/xc7vx485t/tilegrid.json'
src, fasm, out = sys.argv[1:4]
tg = json.load(open(TG)); grid = {(v['grid_x'], v['grid_y']): k for k, v in tg.items()}
d = json.load(open(src)); m = d['modules'][next(iter(d['modules']))]

def tile(xy):
    a = re.fullmatch(r'X(\d+)Y(\d+)', xy); return grid[(int(a[1]), int(a[2]))]
sitecache = {}
def site_of(t, s):
    """a tile-relative site name (TYPE_X<dx>Y<dy>, offsets from the tile's lowest site of that prefix) as a device site name"""
    k = (t, s)
    if k not in sitecache:
        a = re.fullmatch(r'(\w+?)_X(\d+)Y(\d+)', s); pre, dx, dy = a[1], int(a[2]), int(a[3])
        xs = [(int(b[1]), int(b[2])) for b in (re.fullmatch(re.escape(pre) + r'_X(\d+)Y(\d+)', x) for x in tg[t].get('sites', {})) if b]
        if not xs: raise KeyError('%s has no %s site' % (t, pre))
        x0, y0 = min(x for x, _ in xs), min(y for _, y in xs)
        sitecache[k] = '%s_X%dY%d' % (pre, x0 + dx, y0 + dy)
    return sitecache[k]
shapes = collections.Counter(); oddex = {}; jpips = set()
def wire(w):
    if w.startswith('SITEWIRE/'): return w
    p = w.split('/')
    if len(p) == 2 and re.fullmatch(r'X\d+Y\d+', p[0]): return tile(p[0]) + '/' + p[1]
    shapes['odd wire'] += 1; oddex.setdefault('wire', w); return w
def pip(p):
    """himbaechel 'X/dst/src' -> 'src->dst', with site wires as SITEWIRE/site/wire"""
    if not p: return p
    q = p.split('/')
    if len(q) != 3 or not re.fullmatch(r'X\d+Y\d+', q[0]):
        shapes['unparsed'] += 1; oddex.setdefault('unparsed', p); return p
    t = tile(q[0])
    def end(x):
        a = re.fullmatch(r'(\w+_X\d+Y\d+)\.(\S+)', x)
        if a: return 'SITEWIRE/%s/%s' % (site_of(t, a[1]), a[2]), True
        return t + '/' + x, False
    (ds, dsite), (ss, ssite) = end(q[1]), end(q[2])
    shapes[('site' if ssite else 'tile') + '->' + ('site' if dsite else 'tile')] += 1
    if not ssite and not dsite: jpips.add((t, q[1], q[2]))
    return ss + '->' + ds

nr = 0
for k, n in m['netnames'].items():
    a = n.get('attributes', {})
    if 'ROUTING' not in a: continue
    t = a['ROUTING'].split(';'); o = []
    for i in range(0, len(t) - 2, 3):
        o += [wire(t[i]), pip(t[i + 1]), t[i + 2]]
    a['ROUTING'] = ';'.join(o) + (';' if a['ROUTING'].endswith(';') else ''); nr += 1
json.dump(d, open(out, 'w'))

# the FASM agrees?
fp = set()
for l in open(fasm):
    a = re.match(r'(INT_[LR]_X\d+Y\d+)\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\s*$', l)
    if a: fp.add((a[1], a[2], a[3]))
isint = lambda p: p[0].startswith('INT_')
free = lambda p: re.fullmatch(r'(FAN|BYP)_BOUNCE\d', p[1]) and re.fullmatch(r'(FAN|BYP)_ALT\d', p[2]) or (re.fullmatch(r'BYP_ALT\d', p[2]) and re.fullmatch(r'BYP(_L)?\d', p[1]))
a = {p for p in jpips if isint(p) and not free(p)}; b = {p for p in fp if not free(p)}
print(f'{len(m["cells"])} cells, {nr} routed nets'); print('pip shapes', dict(shapes)); print('odd', oddex)
print(f'INT pips: json {len(a)}, fasm {len(b)}, json only {len(a-b)}, fasm only {len(b-a)}')
print(' json only', sorted(a - b)[:8]); print(' fasm only', sorted(b - a)[:8])
sys.exit(1 if a != b else 0)
