#!/usr/bin/env python3
"""decode.py <raw> <out.csv>: raw LFSR counters from atsweep.sh to error counts, and the closing edge of each path"""
import sys, os
sys.path.insert(0, os.path.expanduser('~/synthgui/xc7'))
from at_gen import lfsr16_decode
d = lfsr16_decode(); vco = 1e6 / 1400; rows = []
for l in open(sys.argv[1]):
    t = l.split(); cd, cm = int(t[0]), int(t[1]); c = [d.get(int(v), -1) for v in t[2:]]
    rows.append(((cm / 8 + cd) * vco, c))
with open(sys.argv[2], 'w') as f:
    f.write('offset_ps,' + ','.join(f'path{i}' for i in range(len(rows[0][1]))) + '\n')
    for o, c in rows:
        f.write(f'{o:.0f},' + ','.join(map(str, c)) + '\n'); print(f'{o:7.0f}', ' '.join(f'{x:6d}' for x in c))
