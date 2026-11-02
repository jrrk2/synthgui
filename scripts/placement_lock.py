#!/usr/bin/env python3
"""lock.py NETLIST.json cells_grid.txt OUT.json: pin every cell nextpnr can take a
site/BEL for to where Vivado placed it (NEXTPNR_BEL + BEL_STRENGTH attributes,
the form nextpnr's own --write json uses), so a run on OUT.json tests the
router alone."""
import json, sys, collections

netlist, grid, out = sys.argv[1:4]
d = json.load(open(netlist))
mod = d['modules'][list(d['modules'])[0]]
cells = mod['cells']

# Vivado BEL -> nextpnr bel; cell types we leave to nextpnr (IO, LUTRAM halves, constants)
SKIP = {'VCC', 'GND', 'IBUF', 'OBUF', 'IBUFDS', 'IBUFDS_GTE2', 'GTXE2_CHANNEL', 'RAM64X1D'}
BEL = {'BUFG.BUFG': 'BUFGCTRL', 'DSP48E1.DSP48E1': 'DSP48E1', 'RAMB36E1.RAMB36E1': 'RAMB36E1',
       'MMCME2_ADV.MMCME2_ADV': 'MMCME2_ADV'}
STRENGTH = 6  # STRENGTH_USER
done = collections.Counter(); skipped = collections.Counter(); missing = 0
for line in open(grid):
    f = line.rstrip('\n').split('\t')
    if len(f) < 7:
        continue
    name, ref, site, bel = f[0], f[1], f[2], f[3]
    if ref in SKIP or site == '':
        skipped[ref] += 1
        continue
    if name not in cells:
        missing += 1
        continue
    if bel in BEL:
        b = BEL[bel]
    elif bel.startswith('SLICEL.') or bel.startswith('SLICEM.'):
        b = bel.split('.', 1)[1]
    else:
        skipped[ref + ':' + bel] += 1
        continue
    attrs = cells[name].setdefault('attributes', {})
    attrs['NEXTPNR_BEL'] = f'{site}/{b}'
    attrs['BEL_STRENGTH'] = format(STRENGTH, '032b')
    done[ref] += 1
json.dump(d, open(out, 'w'))
print('locked', sum(done.values()), dict(done))
print('skipped', dict(skipped), 'missing', missing)
