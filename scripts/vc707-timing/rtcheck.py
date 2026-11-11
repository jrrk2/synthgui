#!/usr/bin/env python3
"""rtcheck.py <routed.json> <harness.fasm>: every site exit a route uses through a LUT output ([A-D]MUX <- [A-D]6LUT_O6 / 5LUT_O5)
must have its OUTMUX feature in the FASM. nextpnr before the 2026-11-10 fix wrote OUTMUX only for tiles holding a cell, so a route-through
in an otherwise empty tile got its LUT INIT but an open site exit (the calibrated Linux harness's DDR fault). Exit 1 on any missing."""
import json, os, re, sys
rj, fasm = sys.argv[1:3]
tg = json.load(open(os.path.expanduser('~/synthgui/deps/prjxray-db/virtex7/xc7vx485t/tilegrid.json')))
s2t = {s: t for t, v in tg.items() for s in v.get('sites', {})}
have = set(l.strip() for l in open(fasm) if l.startswith('CLBL'))
m = json.load(open(rj)); m = m['modules'][next(iter(m['modules']))]
ok = 0; miss = []
for k, n in m['netnames'].items():
    r = n.get('attributes', {}).get('ROUTING', '').split(';')
    for i in range(0, len(r) - 2, 3):
        a = re.fullmatch(r'X\d+Y\d+/SLICE_X\dY0\.([A-D])MUX/SLICE_X\dY0\.([A-D])(6LUT_O6|5LUT_O5)', r[i + 1]) if r[i + 1] else None
        if not a: continue
        site = r[i].split('/')[1]; t = s2t[site]
        idx = sorted(x for x in tg[t]['sites'] if x.startswith('SLICE')).index(site)
        half = ('SLICEM_X0' if t.startswith('CLBLM') else 'SLICEL_X0') if idx == 0 else 'SLICEL_X1'
        f = '%s.%s.%sOUTMUX.%s' % (t, half, a[1], 'O6' if a[3] == '6LUT_O6' else 'O5')
        if f in have: ok += 1
        else: miss.append((k, f))
print(f'{ok} LUT site exits with their OUTMUX, {len(miss)} without')
for k, f in miss[:20]: print('  MISSING', f, 'net', k)
sys.exit(1 if miss else 0)
