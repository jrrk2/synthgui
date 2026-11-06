#!/usr/bin/env python3
"""Netlist surgery for a partial-reconfiguration window (yosys/synthgui JSON).

synthgui flattens a design and names its LUTs with no hierarchy, so the
cells of the block that lives in the window cannot be told apart by name
after flattening.  Instead the block is synthesised on its own and merged
into the static design's netlist, where it was left as a black-box instance,
with every cell and net of it prefixed; nextpnr's -o pr-cells=<prefix> then
knows exactly which cells belong in the window.

  merge   --harness H.json --block B.json --instance at_block --prefix at_block. --out M.json
          The harness with the instance replaced by the block's cells, named
          <prefix><name>; the block's port bits become the instance's nets.

  window  --block B.json --harness H.json --instance at_block --interface harness.pri
          --map window-map.json --prefix at_block. --out W.json
          [--reserve reserve.txt [--static-fasm H.fasm --tilegrid T --window x0,y0,x1,y1]]
          The block alone as a top-level design for the window chipdb: each
          port becomes a PARTPIN_IN (input) or PARTPIN_OUT (output) cell
          pinned (BEL attribute) to the boundary node the harness build
          reported for that port's net in its -o pr-interface file, looked
          up in the window chipdb's --window-map.
"""
import argparse
import json
import sys


def top_module(j):
    mods = j["modules"]
    for name, m in mods.items():
        a = m.get("attributes", {})
        if a.get("top") not in (None, 0, "0", "00000000000000000000000000000000"):
            return name, m
    return max(mods.items(), key=lambda kv: len(kv[1]["cells"]))


def all_bits(m):
    for p in m["ports"].values():
        yield from p["bits"]
    for c in m["cells"].values():
        for bits in c["connections"].values():
            yield from bits
    for n in m["netnames"].values():
        yield from n["bits"]


def max_bit(m):
    return max((b for b in all_bits(m) if isinstance(b, int)), default=0)


def cmd_merge(args):
    hj = json.load(open(args.harness))
    hname, H = top_module(hj)
    bj = json.load(open(args.block))
    bname, B = top_module(bj)
    if args.instance not in H["cells"]:
        sys.exit("harness has no cell %s; cells of type %s: %s" %
                 (args.instance, bname, [c for c, v in H["cells"].items() if v["type"] == bname][:5]))
    inst = H["cells"][args.instance]
    offset = max_bit(H) + 1
    bitmap = {}
    for pname, port in B["ports"].items():
        if pname not in inst["connections"]:
            sys.exit("instance %s has no connection for block port %s" % (args.instance, pname))
        hbits = inst["connections"][pname]
        if len(hbits) != len(port["bits"]):
            sys.exit("port %s: %d bits in the block, %d on the instance" % (pname, len(port["bits"]), len(hbits)))
        for bb, hb in zip(port["bits"], hbits):
            bitmap[bb] = hb
    port_bits = set(bitmap)

    def remap(bits):
        out = []
        for b in bits:
            if isinstance(b, str):
                out.append(b)
            elif b in bitmap:
                out.append(bitmap[b])
            else:
                out.append(b + offset)
        return out

    del H["cells"][args.instance]
    for cname, c in B["cells"].items():
        nc = dict(c)
        nc["connections"] = {p: remap(bits) for p, bits in c["connections"].items()}
        H["cells"][args.prefix + cname] = nc
    for nname, n in B["netnames"].items():
        if all(b in port_bits or isinstance(b, str) for b in n["bits"]):
            continue  # a port net keeps the harness's name
        nn = dict(n)
        nn["bits"] = remap(n["bits"])
        H["netnames"][args.prefix + nname] = nn
    with open(args.out, "w") as f:
        json.dump(hj, f, indent=1)
    print("merge: %d cells and %d nets of %s added as %s*, instance %s removed, bits offset by %d -> %s" %
          (len(B["cells"]), len(B["netnames"]), bname, args.prefix, args.instance, offset, args.out))


def read_interface(path):
    """net -> list of (dir, wire), in file order, duplicates dropped"""
    out = {}
    seen = set()
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3 or parts[0].startswith("$PACKER_"):
                continue
            key = tuple(parts)
            if key in seen:
                continue
            seen.add(key)
            out.setdefault(parts[0], []).append((parts[1], parts[2]))
    return out


def cmd_window(args):
    bj = json.load(open(args.block))
    bname, B = top_module(bj)
    hj = json.load(open(args.harness))
    hname, H = top_module(hj)
    inst = H["cells"][args.instance]
    interface = read_interface(args.interface)
    wmap = json.load(open(args.map))
    # harness net names per bit
    names_of_bit = {}
    for nname, n in H["netnames"].items():
        for b in n["bits"]:
            names_of_bit.setdefault(b, []).append(nname)
    W = {"attributes": {"top": "00000000000000000000000000000001"}, "ports": {}, "cells": {}, "netnames": {}}
    for cname, c in B["cells"].items():
        W["cells"][args.prefix + cname] = c
    for nname, n in B["netnames"].items():
        W["netnames"][args.prefix + nname] = n
    pinned = 0
    for pname, port in B["ports"].items():
        hbits = inst["connections"][pname]
        for i, (bb, hb) in enumerate(zip(port["bits"], hbits)):
            cand = names_of_bit.get(hb, [])
            crossings = [(n, interface[n]) for n in cand if n in interface]
            label = pname if len(port["bits"]) == 1 else "%s[%d]" % (pname, i)
            if not crossings:
                sys.exit("port %s: none of the harness nets %s is in the interface file" % (label, cand))
            net, xs = crossings[0]
            want = "in" if port["direction"] == "input" else "out"
            xs = [w for d, w in xs if d == want]
            if not xs:
                sys.exit("port %s: net %s has no '%s' crossing" % (label, net, want))
            if len(xs) > 1:
                print("port %s: net %s crosses %s %d times, pinned to the first (%s); the others are reserved" %
                      (label, net, want, len(xs), xs[0]))
            canon = wmap["wires"].get(xs[0])
            if canon is None:
                sys.exit("port %s: wire %s is not a boundary node of the window map" % (label, xs[0]))
            node = wmap["nodes"][canon]
            bel = node["in"] if want == "in" else node["out"]
            cell = {"hide_name": 0, "type": "PARTPIN_IN" if want == "in" else "PARTPIN_OUT",
                    "parameters": {}, "attributes": {"BEL": bel},
                    "port_directions": {"O": "output"} if want == "in" else {"I": "input"},
                    "connections": {("O" if want == "in" else "I"): [bb]}}
            W["cells"]["pp_" + label] = cell
            W["netnames"][args.prefix + label] = {"hide_name": 0, "bits": [bb], "attributes": {}}
            print("port %-10s %-3s net %-40s node %s -> %s" % (label, want, net, canon, bel))
            pinned += 1
    out = {"creator": "pr_block_json.py window", "modules": {"window": W}}
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1)
    # every node the static design drives into the window that no partition pin
    # took, re-entries included (they float once the window is replaced):
    # reserved, so the window build never routes through such a wire
    if args.reserve:
        taken = {c["attributes"]["BEL"] for c in W["cells"].values() if c["type"] == "PARTPIN_IN"}
        reserved = []
        unknown = 0
        for net, xs in interface.items():
            for d, w in xs:
                if d not in ("in", "reentry"):
                    continue
                canon = wmap["wires"].get(w)
                if canon is None:
                    unknown += 1
                    continue
                bel = wmap["nodes"][canon]["in"]
                if bel not in taken and bel not in reserved:
                    reserved.append(bel)
        # a static net that only runs along a wire overhanging the window is not in the
        # interface file, yet driving that wire from inside the window is a short
        static = []
        if args.static_fasm:
            tiles = json.load(open(args.tilegrid))
            x0, y0, x1, y1 = [int(v) for v in args.window.split(",")]
            have = set(reserved)
            found = set()
            with open(args.static_fasm) as f:
                for line in f:
                    parts = line.strip().split(".")
                    if len(parts) != 3 or parts[0] not in tiles:
                        continue
                    t = tiles[parts[0]]
                    if x0 <= t["grid_x"] <= x1 and y0 <= t["grid_y"] <= y1:
                        continue  # the placeholder's own routes in the window: replaced
                    canon = wmap["wires"].get(parts[0] + "/" + parts[1])
                    if canon is None:
                        continue
                    bel = wmap["nodes"][canon]["in"]
                    if bel not in taken and bel not in have:
                        found.add(bel)
            static = sorted(found)
        with open(args.reserve, "w") as f:
            f.write("# nodes the static design drives into the window, beyond the partition pins\n")
            for bel in reserved:
                f.write(bel + "\n")
            if args.static_fasm:
                f.write("# boundary nodes the static design drives with no consumer in the window\n")
                for bel in static:
                    f.write(bel + "\n")
        print("window: %d driven nodes reserved -> %s%s" %
              (len(reserved), args.reserve, " (%d crossing wires not in the window map)" % unknown if unknown else ""))
        if args.static_fasm:
            print("window: %d more boundary nodes reserved from %s" % (len(static), args.static_fasm))
    print("window: %d cells, %d partition pins -> %s" % (len(W["cells"]), pinned, args.out))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--harness", required=True)
    m.add_argument("--block", required=True)
    m.add_argument("--instance", required=True)
    m.add_argument("--prefix", required=True)
    m.add_argument("--out", required=True)
    w = sub.add_parser("window")
    w.add_argument("--block", required=True)
    w.add_argument("--harness", required=True)
    w.add_argument("--instance", required=True)
    w.add_argument("--interface", required=True)
    w.add_argument("--map", required=True)
    w.add_argument("--prefix", required=True)
    w.add_argument("--out", required=True)
    w.add_argument("--reserve", help="write the bels of the other driven boundary nodes here (nextpnr -o pr-reserve)")
    w.add_argument("--static-fasm", help="the harness FASM: also reserve every boundary node it drives from outside the window")
    w.add_argument("--tilegrid", help="with --static-fasm")
    w.add_argument("--window", help="with --static-fasm: x0,y0,x1,y1")
    args = p.parse_args()
    if args.cmd == "window" and args.static_fasm and not (args.reserve and args.tilegrid and args.window):
        sys.exit("--static-fasm needs --reserve, --tilegrid and --window")
    if args.cmd == "merge":
        cmd_merge(args)
    else:
        cmd_window(args)


if __name__ == "__main__":
    main()
