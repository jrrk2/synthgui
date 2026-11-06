#!/usr/bin/env python3
"""pr_interface_json.py --routed harness.json --tilegrid tilegrid.json --window x0,y0,x1,y1 --prefix at_block. --out interface.txt
The -o pr-interface report recomputed from a routed design's JSON (its ROUTING attributes): for every
crossing net (a pin inside and a pin outside the window), the boundary nodes, classified
in / out (reached from the driver on its own side only) or reentry / reexit (reached through the other side,
so undriven once the window is replaced)."""
import argparse, json, sys

p = argparse.ArgumentParser()
p.add_argument("--routed", required=True); p.add_argument("--tilegrid", required=True)
p.add_argument("--window", required=True); p.add_argument("--prefix", required=True); p.add_argument("--out", required=True)
a = p.parse_args()
x0, y0, x1, y1 = (int(v) for v in a.window.split(","))
tg = json.load(open(a.tilegrid))
byxy = {(t["grid_x"], t["grid_y"]): n for n, t in tg.items()}
def grid(tile):            # "X354Y53" -> (354, 53)
    x, y = tile[1:].split("Y"); return int(x), int(y)
def inside_tile(tile):
    x, y = grid(tile); return x0 <= x <= x1 and y0 <= y <= y1
def real(wire):            # "X355Y80/NE2END1" -> "INT_L_X138Y273/NE2END1"
    t, w = wire.split("/", 1); return byxy.get(grid(t), t) + "/" + w
j = json.load(open(a.routed))
m = max(j["modules"].values(), key=lambda v: len(v["cells"]))
def cell_inside(c):          # the window cells are the ones named by the prefix (nextpnr -o pr-cells)
    return c.startswith(a.prefix)
# net -> (driver cell, [user cells]) from cell connections (output ports drive)
bit_driver, bit_users = {}, {}
for cn, c in m["cells"].items():
    for port, bits in c["connections"].items():
        d = c["port_directions"].get(port, "input")
        for b in bits:
            if isinstance(b, str): continue
            (bit_driver if d == "output" else bit_users.setdefault(b, [])).__setitem__(b, cn) if d == "output" else bit_users.setdefault(b, []).append(cn)
lines, seen = [], set()
nets = 0
for nname, n in m["netnames"].items():
    r = n["attributes"].get("ROUTING")
    if not r or len(n["bits"]) != 1 or isinstance(n["bits"][0], str): continue
    b = n["bits"][0]
    drv = bit_driver.get(b); users = bit_users.get(b, [])
    if drv is None: continue
    sides = {cell_inside(c) for c in [drv] + users} - {None}
    if sides != {True, False}: continue
    drv_inside = cell_inside(drv)
    toks = r.split(";")
    pip_of = {}; 
    for i in range(0, len(toks) - 2, 3):
        pip_of[toks[i]] = toks[i + 1]      # wire -> driving pip ("" for the source)
    memo = {}
    def clean(w):
        if w in memo: return memo[w]
        memo[w] = True
        pip = pip_of.get(w, "")
        ok = True
        if pip:
            pt = pip.split("/")[0]
            ok = (inside_tile(pt) == drv_inside) and clean(pip.rsplit("/", 1)[0] and pip.split("/")[0] + "/" + pip.split("/")[2])
        memo[w] = ok; return ok
    def driven_inside(w):
        pip = pip_of.get(w)
        if pip is None: return None
        return inside_tile(pip.split("/")[0]) if pip else drv_inside
    nets += 1
    for w, pip in pip_of.items():
        if not pip: continue
        t, dst, src = pip.split("/")
        s = t + "/" + src
        si = driven_inside(s)
        if si is None: continue
        di = inside_tile(t)
        if si == di: continue
        d = ("in" if clean(s) else "reentry") if di else ("out" if clean(s) else "reexit")
        line = "%s\t%s\t%s" % (nname, d, real(s))
        if line not in seen:
            seen.add(line); lines.append(line)
open(a.out, "w").write("\n".join(lines) + "\n")
print("%d crossing nets, %d boundary lines -> %s" % (nets, len(lines), a.out))
