#!/usr/bin/env python3
"""Prepare an OpenSTA run from nextpnr-himbaechel (xc7) outputs.

nextpnr writes the routed design (--write routed.json) and an SDF (--sdf routed.sdf)
whose cells are its own physical types (SLICE_LUTX, SLICE_FFX, RAMB36E1_RAMB36E1, ...).
No vendor Liberty describes those, so this script derives one from the SDF itself:
every IOPATH becomes a timing arc (an edge arc when it starts at a clock pin), every
SETUPHOLD a setup/hold check, and cell delays carry the worst SDF value so a run without
read_sdf still sees them.  It also writes a flat Verilog netlist of the routed cells and
a Tcl script for `sta`.

  nextpnr_sta.py --json routed.json --sdf routed.sdf --log pnr.log --out DIR [--clock PIN=NS ...]
"""
import argparse, json, os, re, sys
from collections import defaultdict

# nextpnr's SDF names the BRAM read clocks by their logical pin; the cell ports are the halves
PIN_ALIAS = {("RAMB36E1_RAMB36E1", "CLKARDCLK"): "CLKARDCLKL",
             ("RAMB36E1_RAMB36E1", "CLKBWRCLK"): "CLKBWRCLKL"}

def vid(n):
    return n if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", n) else "\\" + n + " "

def triple_max(t):
    return max(float(x) for x in t.split(":") if x != "") / 1000.0  # ps -> ns

def parse_sdf(text):
    """Per-instance arcs, grouped into variants: each distinct set of IOPATH/SETUPHOLD
    pins becomes its own Liberty cell, so an instance only has the arcs nextpnr gave it
    (a LUT using A1-A3 must not grow false A4-A6 -> O5 arcs from another instance)."""
    arcs = defaultdict(dict)    # variant -> (from,to) -> max ns
    checks = defaultdict(dict)  # variant -> (pin, ref, edge) -> (setup, hold)
    base = {}                   # variant -> physical type
    inst_variant = {}           # instance -> variant
    sig_name = {}
    cells = []
    for body in re.split(r"\n  \(CELL\n", text):
        m = re.search(r'CELLTYPE "([^"]+)"', body)
        i = re.search(r"\(INSTANCE ([^)]*)\)", body)
        if not m or not i or not i.group(1).strip():
            continue
        t, inst = m.group(1), i.group(1).strip().replace("\\", "")
        ia = {}
        for a, b, d in re.findall(r"IOPATH (\S+) (\S+) \(([-\d.:]+)\)", body):
            a = PIN_ALIAS.get((t, a), a); b = PIN_ALIAS.get((t, b), b)
            ia[(a, b)] = max(ia.get((a, b), 0.0), triple_max(d))
        ic = {}
        for p, edge, r, s_, h in re.findall(r"SETUPHOLD \((?:posedge|negedge) (\S+?)\) \((posedge|negedge) (\S+?)\) \(([-\d.:]+)\) \(([-\d.:]+)\)", body):
            r = PIN_ALIAS.get((t, r), r)
            k = (p, r, edge)
            os_, oh = ic.get(k, (-1e9, -1e9))
            ic[k] = (max(os_, triple_max(s_)), max(oh, triple_max(h)))
        sig = (t, frozenset(ia), frozenset(ic))
        if sig not in sig_name:
            n = sum(1 for k in sig_name if k[0] == t)
            sig_name[sig] = t if n == 0 else "%s__v%d" % (t, n)
        v = sig_name[sig]
        base[v] = t
        inst_variant[inst] = v
        for k, d in ia.items():
            arcs[v][k] = max(arcs[v].get(k, 0.0), d)
        for k, (a_, b_) in ic.items():
            o = checks[v].get(k, (-1e9, -1e9))
            checks[v][k] = (max(o[0], a_), max(o[1], b_))
    return arcs, checks, base, inst_variant

def fix_sdf(text, inst_variant):
    """Rename the read clocks and give each CELL the variant its instance uses."""
    def one(body):
        m = re.search(r'CELLTYPE "([^"]+)"', body)
        i = re.search(r"\(INSTANCE ([^)]*)\)", body)
        if not m or not i:
            return body
        t = m.group(1)
        for (ct, a), b in PIN_ALIAS.items():
            if ct == t:
                body = re.sub(r"\b%s\b" % a, b, body)
        v = inst_variant.get(i.group(1).strip().replace("\\", ""), t)
        return body.replace('CELLTYPE "%s"' % t, 'CELLTYPE "%s"' % v, 1)
    parts = re.split(r"(\n  \(CELL\n)", text)
    return "".join(one(x) if k % 2 == 0 else x for k, x in enumerate(parts))

def scalar(v):
    return '(scalar) { values("%.4f"); }' % v

def write_lib(path, types, arcs, checks):
    out = ["library(nextpnr_xc7) {",
           "  delay_model : table_lookup;",
           '  time_unit : "1ns"; voltage_unit : "1V"; current_unit : "1mA";',
           '  pulling_resistance_unit : "1kohm"; leakage_power_unit : "1nW";',
           "  capacitive_load_unit (1, pf);",
           "  input_threshold_pct_rise : 50; input_threshold_pct_fall : 50;",
           "  output_threshold_pct_rise : 50; output_threshold_pct_fall : 50;",
           "  slew_lower_threshold_pct_rise : 20; slew_upper_threshold_pct_rise : 80;",
           "  slew_lower_threshold_pct_fall : 20; slew_upper_threshold_pct_fall : 80;",
           "  nom_voltage : 1.0; nom_temperature : 25; nom_process : 1;"]
    for t in sorted(types):
        dirs = types[t]
        clocks = {r for (_, r, _) in checks.get(t, {})}
        clocks |= {a for (a, _) in arcs.get(t, {}) if re.fullmatch(r"CK|CLK\w*", a)}
        out.append('  cell("%s") {' % t)
        for p in sorted(dirs):
            d = {"input": "input", "output": "output", "inout": "inout"}[dirs[p]]
            out.append('    pin("%s") {' % p)
            out.append("      direction : %s;" % d)
            if d != "output":
                out.append("      capacitance : 0;")
            if p in clocks:
                out.append("      clock : true;")
            for (a, b), v in sorted(arcs.get(t, {}).items()):
                if b != p or a not in dirs:
                    continue
                out.append('      timing() { related_pin : "%s";' % a)
                out.append("        timing_type : rising_edge;" if a in clocks else "        timing_sense : non_unate;")
                out.append("        cell_rise %s cell_fall %s" % (scalar(v), scalar(v)))
                out.append("        rise_transition %s fall_transition %s }" % (scalar(0), scalar(0)))
            for (pin, ref, edge), (s, h) in sorted(checks.get(t, {}).items()):
                if pin != p or ref not in dirs:
                    continue
                e = "rising" if edge == "posedge" else "falling"
                for kind, v in (("setup", s), ("hold", h)):
                    out.append('      timing() { related_pin : "%s"; timing_type : %s_%s;' % (ref, kind, e))
                    out.append("        rise_constraint %s fall_constraint %s }" % (scalar(v), scalar(v)))
            out.append("    }")
        out.append("  }")
    out.append("}")
    open(path, "w").write("\n".join(out) + "\n")

def write_netlist(path, mod, inst_variant):
    names = {}
    for n, nn in sorted(mod["netnames"].items(), key=lambda kv: (kv[0].startswith("$"), kv[1].get("hide_name", 0), len(kv[0]))):
        for i, b in enumerate(nn["bits"]):
            if isinstance(b, int) and b not in names:
                names[b] = n if len(nn["bits"]) == 1 else "%s[%d]" % (n, i)
    used = set()
    def net(b):
        if b in ("0", "1"):
            return "1'b" + b
        if b in ("x", "z"):
            return "1'bx"
        used.add(b)
        return vid(names.get(b, "n%d" % b))
    insts = []
    for cn, c in mod["cells"].items():
        conns = ["." + vid(p).rstrip() + "(" + net(bits[0]) + ")" for p, bits in sorted(c["connections"].items()) if bits]
        insts.append("  %s %s(%s);" % (vid(inst_variant.get(cn, c["type"])), vid(cn), ", ".join(conns)))
    ports = [(p, v["direction"], v["bits"]) for p, v in mod.get("ports", {}).items()]
    out = ["module top(%s);" % ", ".join(vid(names.get(b[0], p)) for p, _, b in ports if b)]
    for p, d, b in ports:
        if b:
            out.append("  %s %s;" % (d, vid(names.get(b[0], p))))
    declared = {names.get(b[0], p) for p, _, b in ports if b}
    for b in sorted(used):
        n = names.get(b, "n%d" % b)
        if n not in declared:
            out.append("  wire %s;" % vid(n)); declared.add(n)
    out += insts + ["endmodule"]
    open(path, "w").write("\n".join(out) + "\n")
    return names

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--sdf", required=True)
    ap.add_argument("--log", help="nextpnr log: clock targets come from its 'PASS/FAIL at F MHz' lines")
    ap.add_argument("--out", required=True)
    ap.add_argument("--clock", action="append", default=[], help="PIN=PERIOD_NS, e.g. clkgen_clk_sys_bufg/O=20")
    ap.add_argument("--paths", type=int, default=5)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    mod = json.load(open(a.json))["modules"]["top"]
    sdf = open(a.sdf).read()
    arcs, checks, base, inst_variant = parse_sdf(sdf)
    ports = {}
    for c in mod["cells"].values():
        ports.setdefault(c["type"], {}).update(c["port_directions"])
    types = {t: dict(d) for t, d in ports.items()}
    for v, t in base.items():
        types[v] = ports.get(t, {})
    write_lib(os.path.join(a.out, "nextpnr_xc7.lib"), types, arcs, checks)
    write_netlist(os.path.join(a.out, "routed.v"), mod, inst_variant)
    open(os.path.join(a.out, "routed.sdf"), "w").write(fix_sdf(sdf, inst_variant))

    clocks = [c.split("=") for c in a.clock]
    if not clocks:
        # every global buffer that drives something, at the slowest target nextpnr reported
        mhz = 50.0
        if a.log:
            f = re.findall(r"(?:PASS|FAIL) at ([\d.]+) MHz", open(a.log, errors="replace").read())
            if f:
                mhz = min(float(x) for x in f)
        loads = defaultdict(int)
        for c in mod["cells"].values():
            for p, bits in c["connections"].items():
                if c["port_directions"].get(p) == "input":
                    for b in bits:
                        loads[b] += 1
        for cn, c in mod["cells"].items():
            if c["type"] == "BUFGCTRL" and loads[c["connections"]["O"][0]] > 0:
                clocks.append((cn + "/O", "%.3f" % (1000.0 / mhz)))
    tcl = ["read_liberty nextpnr_xc7.lib", "read_verilog routed.v", "link_design top"]
    for i, (pin, per) in enumerate(clocks):
        nm = pin.split("/")[0].replace("clkgen_", "").replace("_bufg", "")
        tcl.append("create_clock -name %s -period %s [get_pins {%s}]" % (nm, per, pin))
    tcl += ["set_propagated_clock [all_clocks]",
            "read_sdf routed.sdf",
            "report_checks -path_delay max -group_path_count %d -fields {fanout} -format full_clock_expanded -digits 3" % a.paths,
            "report_checks -path_delay min -digits 3",
            "report_tns", "report_wns", "report_clock_min_period", "exit"]
    open(os.path.join(a.out, "sta.tcl"), "w").write("\n".join(tcl) + "\n")
    print("wrote %s: %d cell variants, %d cells, clocks %s" % (a.out, len(types), len(mod["cells"]), ", ".join("%s=%sns" % tuple(c) for c in clocks)))

if __name__ == "__main__":
    main()
