#!/usr/bin/env python3
"""lane_macro.py -- splice a once-mapped block into a mapped top, N times.

  lane_macro.py merge <top.json> <block.json> <out.json> [--type heavyhash_lane]

<top.json> is the verilator --map-only-output netlist of the design with the
block black-boxed (--struct-only-blackbox heavyhash_lane): every instance is
one cell of type heavyhash_lane.  <block.json> is the block mapped on its own
(--top-module heavyhash_lane --map-only-no-iobuf): one ABC run.  Each instance
cell is replaced by a copy of the block's cells and nets, named
<instance>__<block cell name>, its port bits joined to the instance's
connections.  Every copy has the same cell names behind its prefix, which is
what lets one placement of the block be stamped onto all of them.

The output is one flat module, as nextpnr reads it.
"""
import argparse
import json
import sys


class Bits:
    """Union-find over top-level net bit ids, plus constants."""

    def __init__(self):
        self.parent = {}
        self.const = {}  # root -> "0"/"1"/"x"

    def find(self, b):
        if not isinstance(b, int):
            return b
        p = self.parent.setdefault(b, b)
        while p != self.parent.setdefault(p, p):
            self.parent[p] = self.parent[self.parent[p]]
            p = self.parent[p]
        self.parent[b] = p
        return p

    def union(self, a, b):
        if not isinstance(a, int) and not isinstance(b, int):
            if a != b:
                print(f"lane_macro: constant {a} joined to constant {b}", file=sys.stderr)
            return
        if not isinstance(a, int):
            a, b = b, a
        ra = self.find(a)
        if not isinstance(b, int):
            self.const[ra] = b
            return
        rb = self.find(b)
        if ra != rb:
            self.parent[rb] = ra
            if rb in self.const:
                self.const.setdefault(ra, self.const.pop(rb))

    def resolve(self, b):
        if not isinstance(b, int):
            return b
        r = self.find(b)
        return self.const.get(r, r)


def max_bit(mod):
    m = 1
    for p in mod.get("ports", {}).values():
        m = max([m] + [b for b in p["bits"] if isinstance(b, int)])
    for c in mod.get("cells", {}).values():
        for bits in c.get("connections", {}).values():
            m = max([m] + [b for b in bits if isinstance(b, int)])
    for n in mod.get("netnames", {}).values():
        m = max([m] + [b for b in n["bits"] if isinstance(b, int)])
    return m


def only_module(js, name=None):
    mods = js["modules"]
    if name:
        return mods[name]
    real = [k for k, v in mods.items() if not v.get("attributes", {}).get("blackbox")]
    if len(real) != 1:
        sys.exit(f"lane_macro: expected one module, found {sorted(mods)}")
    return mods[real[0]], real[0]


def merge(top_path, block_path, out_path, block_type):
    top_js = json.load(open(top_path))
    block_js = json.load(open(block_path))
    top, top_name = only_module(top_js)
    block = block_js["modules"].get(block_type) or only_module(block_js)[0]

    next_id = max_bit(top) + 1
    bits = Bits()
    new_cells, new_nets = {}, {}
    insts = [(n, c) for n, c in top["cells"].items() if c["type"] == block_type]
    if not insts:
        sys.exit(f"lane_macro: no cells of type {block_type} in {top_path}")

    for inst, cell in insts:
        conns = cell["connections"]
        local = {}  # block bit id -> top bit id (this instance)

        def top_bit(b):
            nonlocal next_id
            if not isinstance(b, int):
                return b
            if b not in local:
                local[b] = next_id
                next_id += 1
            return local[b]

        # the block's ports are the instance's connections
        for pname, port in block["ports"].items():
            tb = conns.get(pname)
            if tb is None:
                sys.exit(f"lane_macro: {inst} has no connection for port {pname}")
            if len(tb) != len(port["bits"]):
                sys.exit(f"lane_macro: {inst}.{pname}: {len(tb)} bits connected, block port has {len(port['bits'])}")
            for lb, t in zip(port["bits"], tb):
                if isinstance(lb, int):
                    if lb in local:
                        bits.union(local[lb], t)  # one block net on two ports
                    else:
                        local[lb] = t
                else:
                    bits.union(t, lb)  # the block drives a constant out
        for cname, c in block["cells"].items():
            nc = dict(c)
            nc["connections"] = {p: [top_bit(b) for b in bl] for p, bl in c["connections"].items()}
            new_cells[f"{inst}__{cname}"] = nc
        named = set()
        for nname, n in block.get("netnames", {}).items():
            nn = dict(n)
            nn["bits"] = [top_bit(b) for b in n["bits"]]
            new_nets[f"{inst}__{nname}"] = nn
            named.update(b for b in n["bits"] if isinstance(b, int))
        # A net with no name gets one from nextpnr's frontend, numbered by a
        # counter over the whole design ($frontend$<n>), and the packer names
        # cells after nets -- so the same net would be called something else in
        # every copy.  Name every unnamed block net per copy instead.
        for c in block["cells"].values():
            for bl in c["connections"].values():
                for b in bl:
                    if isinstance(b, int) and b not in named:
                        named.add(b)
                        new_nets[f"{inst}__n{b}"] = {"hide_name": 1, "bits": [top_bit(b)], "attributes": {}}
        del top["cells"][inst]

    top["cells"].update(new_cells)
    top.setdefault("netnames", {}).update(new_nets)

    def fix(bl):
        return [bits.resolve(b) for b in bl]
    for c in top["cells"].values():
        c["connections"] = {p: fix(bl) for p, bl in c["connections"].items()}
    for n in top["netnames"].values():
        n["bits"] = fix(n["bits"])
    for p in top["ports"].values():
        p["bits"] = fix(p["bits"])

    top_js["modules"] = {k: v for k, v in top_js["modules"].items() if k != block_type}
    json.dump(top_js, open(out_path, "w"))
    print(f"lane_macro: {len(insts)} x {block_type} ({len(block['cells'])} cells each) "
          f"spliced into {top_name}: {len(top['cells'])} cells")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("top")
    m.add_argument("block")
    m.add_argument("out")
    m.add_argument("--type", default="heavyhash_lane")
    a = ap.parse_args()
    if a.cmd == "merge":
        merge(a.top, a.block, a.out, a.type)


if __name__ == "__main__":
    main()
