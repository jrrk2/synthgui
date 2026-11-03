#!/usr/bin/env python3
"""bels2preplaced.py NETLIST.json sites.txt bels.txt OUTDIR

Convert place_lef's BEL stamps (lines `cell<TAB>SITE/BEL`, site-form names such
as SLICE_X10Y20/AFF) into
  OUTDIR/preplaced.txt   nextpnr himbaechel `-o preplaced=` form
                         (cell<TAB>X<col>Y<row>/<SITE_X<dx>Y<dy>.<BEL>)
  OUTDIR/cells_grid.txt  the Vivado-dump form placement_fom.py reads
                         (cell, type, site, bel, tile, col, row)
Cells the placer invented (carry replicas, hold buffers) are dropped; cells of
the netlist left unstamped are counted and listed in OUTDIR/unplaced.txt.
"""
import collections, json, os, re, sys

netlist, sites_path, bels_path, outdir = sys.argv[1:5]
os.makedirs(outdir, exist_ok=True)

site_info = {}                      # site -> (tile, col, row)
tile_min = collections.defaultdict(lambda: [10**9, 10**9])  # (tile, prefix) -> [minx, miny]
for line in open(sites_path):
    f = line.rstrip('\n').split('\t')
    if len(f) < 5:
        continue
    site, tile, col, row = f[0], f[1], int(f[2]), int(f[3])
    site_info[site] = (tile, col, row)
    m = re.match(r'(.*)_X(\d+)Y(\d+)$', site)
    if m:
        k = (tile, m.group(1))
        tile_min[k][0] = min(tile_min[k][0], int(m.group(2)))
        tile_min[k][1] = min(tile_min[k][1], int(m.group(3)))

d = json.load(open(netlist))
mod = d['modules'][list(d['modules'])[0]]
cells = mod['cells']

BEL_FIX = {'RAMB36E1': 'RAMB36E1~RAMB36E1', 'RAMB36': 'RAMB36E1~RAMB36E1'}

out_pre = open(os.path.join(outdir, 'preplaced.txt'), 'w')
out_grid = open(os.path.join(outdir, 'cells_grid.txt'), 'w')
stamped = set()
dropped = collections.Counter()
bad_site = collections.Counter()
by_type = collections.Counter()
for line in open(bels_path):
    line = line.rstrip('\n')
    if '\t' not in line:
        continue
    cell, loc = line.split('\t', 1)
    if cell not in cells:
        dropped[re.sub(r'\d+', 'N', cell)[:40]] += 1
        continue
    if '/' not in loc:
        bad_site['no-bel:' + loc] += 1
        continue
    site, bel = loc.split('/', 1)
    if site not in site_info:
        bad_site[re.sub(r'\d+', 'N', site)] += 1
        continue
    tile, col, row = site_info[site]
    m = re.match(r'(.*)_X(\d+)Y(\d+)$', site)
    prefix = m.group(1)
    mn = tile_min[(tile, prefix)]
    dx, dy = int(m.group(2)) - mn[0], int(m.group(3)) - mn[1]
    bel = BEL_FIX.get(bel, bel)
    t = cells[cell]['type']
    out_pre.write('%s\tX%dY%d/%s_X%dY%d.%s\n' % (cell, col, row, prefix, dx, dy, bel))
    out_grid.write('%s\t%s\t%s\t%s\t%s\t%d\t%d\n' % (cell, t, site, bel, tile, col, row))
    stamped.add(cell)
    by_type[t] += 1
out_pre.close(); out_grid.close()

unplaced = collections.Counter()
with open(os.path.join(outdir, 'unplaced.txt'), 'w') as f:
    for cn, c in cells.items():
        if cn not in stamped:
            unplaced[c['type']] += 1
            f.write('%s\t%s\n' % (cn, c['type']))
print('stamped %d of %d cells' % (len(stamped), len(cells)))
print('by type:', dict(by_type.most_common(12)))
print('netlist cells without a stamp:', dict(unplaced.most_common(12)))
print('placer-only cells dropped:', dict(dropped.most_common(8)))
if bad_site:
    print('unknown sites:', dict(bad_site.most_common(8)))
