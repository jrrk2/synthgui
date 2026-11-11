#!/usr/bin/env python3
"""pathcmp.py <vivado report_timing file> <nextpnr harness.sdf> <routed.json> [path number, from 1]: one Vivado setup path, hop by hop,
against nextpnr's own SDF (max values) for the same pins. Vivado's logical LUT pins (I<n>, O) are mapped to the physical pins nextpnr
wrote (A<j>, O6/O5) by X_ORIG_PORT_* in the routed JSON; bus pins X[n] become Xn. Delays in ps."""
import json, re, sys
rpt, sdf, rj = sys.argv[1:4]; which = int(sys.argv[4]) if len(sys.argv) > 4 else 1
m = json.load(open(rj)); m = m['modules'][next(iter(m['modules']))]; cells = m['cells']
inter, iop, setup = {}, {}, {}; cur = None
for l in open(sdf):
    if 'INTERCONNECT' in l:
        a = re.search(r'\(INTERCONNECT (\S+) (\S+) \(([\d.]+):([\d.]+):([\d.]+)\)', l)
        if a: inter[(a[1].replace('\\', ''), a[2].replace('\\', ''))] = float(a[5]); continue
    a = re.search(r'\(INSTANCE (\S+)\)', l)
    if a: cur = a[1].replace('\\', ''); continue
    a = re.search(r'\(IOPATH (\S+) (\S+) \(([\d.]+):([\d.]+):([\d.]+)\)', l)
    if a: iop[(cur, a[1], a[2])] = float(a[5]); continue
    a = re.search(r'\(SETUPHOLD \(posedge (\S+)\) \(posedge (\S+)\) \(([\d.]+):([\d.]+):([\d.]+)\)', l)
    if a: setup[(cur, a[1])] = float(a[5])
def pins(cell, pin):
    c = cells.get(cell)
    b = re.fullmatch(r'(\w+)\[(\d+)\]', pin)
    if b: return [b[1] + b[2], b[1] + 'L' + b[2], b[1] + 'U' + b[2]]
    if c is not None and c['type'] == 'SLICE_LUTX':
        if re.fullmatch(r'I\d', pin):
            return [p[12:] for p, v in c['attributes'].items() if p.startswith('X_ORIG_PORT_A') and pin in v.split()]
        if pin == 'O':
            return [p[12:] for p, v in c['attributes'].items() if p.startswith('X_ORIG_PORT_O') and v == 'O']
    return [pin, pin + 'L', pin + 'U']
body = open(rpt).read().split('\nSlack')[which]
head = [l for l in body.split('\n')[:12] if 'Source:' in l or 'Destination:' in l or 'Data Path Delay' in l]
secs = re.split(r'\n\s+-{60,}\s+-{10,}\n', body)
data = secs[2].split('\n')          # [0] header, [1] source clock path, [2] data path, [3] destination clock
lines = []
for l in data:   # join a "(Prop_...)" header with its value line
    if lines and re.search(r"\((Prop|Setup)_[^)]+\)\s*$", lines[-1]) and re.match(r'\s+-?[\d.]+\s+-?[\d.]+', l): lines[-1] += ' ' + l.strip()
    else: lines.append(l)
ev = []
for l in lines:
    a = re.search(r'\(Prop_\w+?_(\w+?)_(\S+?)\)\s+([\d.]+)\s+([\d.]+)\s+[rf]\s+(\S+)/(\S+)\s*$', l)
    if a: ev.append(('cell', a[5], a[1], a[2], float(a[3]))); continue
    a = re.search(r'net \(fo=(\d+), (\w+)\)\s+([\d.]+)\s+([\d.]+)\s+(\S+)', l)
    if a: ev.append(('net', a[5], int(a[1]), a[2], float(a[3]))); continue
    a = re.search(r'\s[rf]\s+(\S+)/(\S+)\s*$', l)
    if a: ev.append(('sink', a[1], a[2]))
sink = re.search(r'\(Setup_\w+?_(\w+?)_(\S+?)\)\s+(-?[\d.]+)', secs[3]) if len(secs) > 3 else None
print('\n'.join(h.strip() for h in head))
print(f"{'element':78s} {'vivado':>7s} {'nextpnr':>7s} {'ratio':>6s}")
tv = tn = 0; drv = None
def row(name, v, n):
    global tv, tn
    tv += v; tn += n if n is not None else 0
    print(f"{name:78s} {v:7.0f} {('%7.0f' % n) if n is not None else '      ?'} {('%6.2f' % (v / n)) if n else ''}")
for i, e in enumerate(ev):
    if e[0] == 'cell':
        cell, ip, op, v = e[1], e[2], e[3], e[4] * 1000
        n = None
        for a in pins(cell, ip):
            for b in pins(cell, op):
                n = iop.get((cell, a, b), n)
        row(f"cell {cells.get(cell, {}).get('type', '?'):10s} {cell[-30:]} {ip}->{op}", v, n); drv = (cell, op)
    elif e[0] == 'net':
        nxt = next((x for x in ev[i + 1:] if x[0] in ('cell', 'sink')), None)
        scell, spin = (nxt[1], nxt[2]) if nxt else (None, None)
        n = None
        for a in pins(*drv):
            for b in pins(scell, spin):
                n = inter.get((drv[0] + '/' + a, scell + '/' + b), n)
        row(f"net  {e[1][-30:]:30s} fo={e[2]:<3d} {e[3]:9s} -> {scell[-20:]}/{spin}", e[4] * 1000, n)
if sink:
    last = [x for x in ev if x[0] == 'sink'][-1]
    n = None
    for b in pins(last[1], last[2]):
        n = setup.get((last[1], b), n)
    row(f"setup {last[1][-30:]}/{last[2]}", float(sink[3]) * -1000, n)
print(f"{'data path + setup':78s} {tv:7.0f} {tn:7.0f} {tv / tn:6.2f}")
