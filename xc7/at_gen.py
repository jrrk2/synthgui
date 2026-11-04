#!/usr/bin/env python3
"""Generate an at-speed test block as a yosys-style JSON netlist for nextpnr.

The block has the seven-port interface of at_block.v (clk_l, clk_c, rst,
run, ld, sh_en, sh_out) and the same protocol, with NPATHS paths under test
instead of one.  It is written as cells (FDRE/FDSE, LUTn) rather than
Verilog so that no synthesiser can restructure a path: a path of depth d is
exactly d LUT2 stages, each XORing the previous stage with a bit of the
results shift chain (0 while a test runs, so the capture value equals the
launch value and the error flag reads directly).

Per path i:
  lq[i]  FDRE clk_l, CE = run, D = b (the LFSR launch bit)
  s0 = lq[i]; s_k = s_{k-1} ^ sh[(7 i + k) mod 16 NPATHS]   (k = 1..depth)
  rq[i]  FDRE clk_c, D = lq[i]      (the reference: the shortest path)
  cq[i]  FDRE clk_c, D = s_depth    (the capture)
  e[i]   FDRE clk_c, D = rq[i] ^ cq[i]
  cnt[i] 16-bit LFSR counter in clk_c, CE = run_c & e[i], set to 1 by rst_c;
         the host decodes its state to a count (lfsr16_decode()).
The shift chain (clk_l) loads {cnt[0], cnt[1], ...} on ld (path 0 at the
output end, MSB first), shifts on sh_en, clears on rst.

usage: at_gen.py --depths 0,1,2,4,8 out.json
"""
import argparse
import json


class Net:
    def __init__(self):
        self.n = 2  # 0 and 1 are reserved spellings for constants in yosys JSON ("0"/"1" strings)
        self.names = {}

    def new(self, name=None):
        b = self.n
        self.n += 1
        if name:
            self.names[name] = b
        return b


def lut_init(nin, fn):
    """INIT string for a LUT with nin inputs, fn(index) -> 0/1; yosys spells
    INIT MSB first, bit i of INIT is the output for inputs I(n-1)..I0 = i."""
    return "".join("1" if fn(i) else "0" for i in range(2 ** nin - 1, -1, -1))


def parity(i):
    return bin(i).count("1") & 1


class Gen:
    def __init__(self):
        self.net = Net()
        self.cells = {}

    def ff(self, name, clk, d, q, ce="1", rst=None, set_=None):
        if set_ is not None:
            self.cells[name] = {"hide_name": 0, "type": "FDSE", "parameters": {"INIT": "1"}, "attributes": {},
                                "port_directions": {"C": "input", "CE": "input", "D": "input", "S": "input",
                                                    "Q": "output"},
                                "connections": {"C": [clk], "CE": [ce], "D": [d], "S": [set_], "Q": [q]}}
        else:
            self.cells[name] = {"hide_name": 0, "type": "FDRE", "parameters": {"INIT": "0"}, "attributes": {},
                                "port_directions": {"C": "input", "CE": "input", "D": "input", "R": "input",
                                                    "Q": "output"},
                                "connections": {"C": [clk], "CE": [ce], "D": [d], "R": [rst if rst is not None else "0"],
                                                "Q": [q]}}

    def lut(self, name, inputs, fn, out):
        n = len(inputs)
        pd = {"I%d" % i: "input" for i in range(n)}
        pd["O"] = "output"
        conn = {"I%d" % i: [b] for i, b in enumerate(inputs)}
        conn["O"] = [out]
        self.cells[name] = {"hide_name": 0, "type": "LUT%d" % n, "parameters": {"INIT": lut_init(n, fn)},
                            "attributes": {}, "port_directions": pd, "connections": conn}


def build(depths):
    g = Gen()
    net = g.net
    npaths = len(depths)
    clk_l, clk_c = net.new("clk_l"), net.new("clk_c")
    rst, run, ld, sh_en, sh_out = net.new("rst"), net.new("run"), net.new("ld"), net.new("sh_en"), net.new("sh_out")

    # launch LFSR: x^32 + x^22 + x^2 + x + 1, seed 0xACE12357, advances while run, set by rst
    seed = 0xACE12357
    lfsr = [net.new("lfsr[%d]" % i) for i in range(32)]
    fb = net.new("lfsr_fb")
    g.lut("lfsr_fb", [lfsr[31], lfsr[21], lfsr[1], lfsr[0]], parity, fb)
    for i in range(32):
        d = fb if i == 0 else lfsr[i - 1]
        # rst loads the seed: a set flop for a 1 bit, a reset flop for a 0 bit; CE = run | rst
        pass
    for i in range(32):
        d = fb if i == 0 else lfsr[i - 1]
        dr = net.new("lfsr_d%d" % i)
        if (seed >> i) & 1:
            # rst ? 1 : (run ? d : q)   with I0 = q, I1 = d, I2 = run, I3 = rst
            g.lut("lfsr_mux_%d" % i, [lfsr[i], d, run, rst], lambda x: 1 if x & 8 else (((x >> 1) & 1) if x & 4 else x & 1), dr)
            g.ff("lfsr_%d" % i, clk_l, dr, lfsr[i])
        else:
            # run ? d : q, and the flop resets on rst
            g.lut("lfsr_mux_%d" % i, [lfsr[i], d, run], lambda x: (x >> 1) & 1 if x & 4 else x & 1, dr)
            g.ff("lfsr_%d" % i, clk_l, dr, lfsr[i], rst=rst)
    b = lfsr[0]

    # run and rst into the capture domain
    run_c0, run_c, rst_c0, rst_c = net.new("run_c0"), net.new("run_c"), net.new("rst_c0"), net.new("rst_c")
    g.ff("run_c0", clk_c, run, run_c0)
    g.ff("run_c", clk_c, run_c0, run_c)
    g.ff("rst_c0", clk_c, rst, rst_c0)
    g.ff("rst_c", clk_c, rst_c0, rst_c)

    nsh = 16 * npaths
    sh = [net.new("sh[%d]" % i) for i in range(nsh)]
    cnt = []
    for p, depth in enumerate(depths):
        lq = net.new("lq[%d]" % p)
        lqd = net.new("lqd[%d]" % p)
        g.lut("lq_mux_%d" % p, [lq, b, run], lambda x: (x >> 1) & 1 if x & 4 else x & 1, lqd)  # run ? b : lq
        g.ff("lq_%d" % p, clk_l, lqd, lq)
        s = lq
        for k in range(1, depth + 1):
            t = net.new("path%d_s%d" % (p, k))
            g.lut("path%d_s%d" % (p, k), [s, sh[(7 * p + k) % nsh]], parity, t)
            s = t
        rq, cq, e = net.new("rq[%d]" % p), net.new("cq[%d]" % p), net.new("e[%d]" % p)
        g.ff("rq_%d" % p, clk_c, lq, rq)
        g.ff("cq_%d" % p, clk_c, s, cq)
        ed = net.new("ed[%d]" % p)
        g.lut("e_lut_%d" % p, [rq, cq], parity, ed)
        g.ff("e_%d" % p, clk_c, ed, e)
        # 16-bit LFSR counter x^16 + x^14 + x^13 + x^11, state 1 after rst, steps on run_c & e
        c = [net.new("cnt%d[%d]" % (p, i)) for i in range(16)]
        cfb = net.new("cnt%d_fb" % p)
        g.lut("cnt%d_fb" % p, [c[15], c[13], c[12], c[10]], parity, cfb)
        for i in range(16):
            d = cfb if i == 0 else c[i - 1]
            d1 = net.new("cnt%d_d%d" % (p, i))
            if i == 0:
                # rst_c ? 1 : ((run_c & e) ? d : q)   with I0 = q, I1 = d, I2 = run_c, I3 = e, I4 = rst_c
                g.lut("cnt%d_mux%d" % (p, i), [c[i], d, run_c, e, rst_c],
                      lambda x: 1 if x & 16 else (((x >> 1) & 1) if (x & 12) == 12 else x & 1), d1)
                g.ff("cnt%d_%d" % (p, i), clk_c, d1, c[i])
            else:
                # (run_c & e) ? d : q, reset on rst_c
                g.lut("cnt%d_mux%d" % (p, i), [c[i], d, run_c, e],
                      lambda x: ((x >> 1) & 1) if (x & 12) == 12 else x & 1, d1)
                g.ff("cnt%d_%d" % (p, i), clk_c, d1, c[i], rst=rst_c)
        cnt.append(c)

    # results shift chain: sh[nsh-1] is sh_out; on ld, path 0's counter lands in the top 16 bits
    # (MSB at the top), path 1 below it, ...; shifts up by one on sh_en; clears on rst
    load = []
    for p in range(npaths):
        for i in range(16):
            load.append(cnt[p][i])  # position: path p bit i -> sh[nsh - 16*(p+1) + i]
    # no clock-enable nets anywhere: the enables are folded into the D muxes
    # (the hold-fix pass double-buffers two flops sharing a slice CE mux)
    for j in range(nsh):
        p = (nsh - 1 - j) // 16
        i = j - (nsh - 16 * (p + 1))
        src = cnt[p][i]
        prev = sh[j - 1] if j > 0 else "0"
        d = net.new("shd[%d]" % j)
        # ld ? src : (sh_en ? prev : q)   with I0 = q, I1 = prev, I2 = src, I3 = sh_en, I4 = ld
        g.lut("sh_mux_%d" % j, [sh[j], prev, src, sh_en, ld],
              lambda x: ((x >> 2) & 1) if x & 16 else (((x >> 1) & 1) if x & 8 else x & 1), d)
        g.ff("sh_%d" % j, clk_l, d, sh[j], rst=rst)
    g.cells["sh_out_buf"] = {"hide_name": 0, "type": "LUT1", "parameters": {"INIT": "10"}, "attributes": {},
                             "port_directions": {"I0": "input", "O": "output"},
                             "connections": {"I0": [sh[nsh - 1]], "O": [sh_out]}}

    ports = {"clk_l": ("input", clk_l), "clk_c": ("input", clk_c), "rst": ("input", rst), "run": ("input", run),
             "ld": ("input", ld), "sh_en": ("input", sh_en), "sh_out": ("output", sh_out)}
    mod = {"attributes": {"top": "00000000000000000000000000000001"},
           "ports": {k: {"direction": d, "bits": [bit]} for k, (d, bit) in ports.items()},
           "cells": g.cells,
           "netnames": {k: {"hide_name": 0, "bits": [v], "attributes": {}} for k, v in net.names.items()}}
    return {"creator": "at_gen.py", "modules": {"at_block": mod}}


def lfsr16_decode():
    """state -> number of steps from the reset state 1."""
    table = {}
    s = 1
    for k in range(65535):
        table[s] = k
        fbit = ((s >> 15) ^ (s >> 13) ^ (s >> 12) ^ (s >> 10)) & 1
        s = ((s << 1) & 0xFFFF) | fbit
    return table


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--depths", required=True, help="comma-separated LUT depth of each path, e.g. 0,1,2,4,8")
    p.add_argument("out")
    args = p.parse_args()
    depths = [int(v) for v in args.depths.split(",")]
    j = build(depths)
    with open(args.out, "w") as f:
        json.dump(j, f, indent=1)
    m = j["modules"]["at_block"]
    types = {}
    for c in m["cells"].values():
        types[c["type"]] = types.get(c["type"], 0) + 1
    print("at_gen: %d paths (depths %s), %d cells: %s -> %s" %
          (len(depths), depths, len(m["cells"]), " ".join("%s=%d" % kv for kv in sorted(types.items())), args.out))


if __name__ == "__main__":
    main()
