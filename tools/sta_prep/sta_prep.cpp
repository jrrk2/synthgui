// sta-prep -- prepare an OpenSTA run from nextpnr-himbaechel (xc7) outputs (sta/nextpnr_sta.py in C++).
//
//   synthgui --tool sta-prep --json routed.json --sdf routed.sdf --log pnr.log --out DIR [--clock PIN=NS ...] [--paths N]
//
// nextpnr writes the routed design (--write routed.json) and an SDF (--sdf routed.sdf) whose cells are its own physical
// types (SLICE_LUTX, SLICE_FFX, RAMB36E1_RAMB36E1, ...). No vendor Liberty describes those, so this derives one from the
// SDF itself: every IOPATH becomes a timing arc (an edge arc when it starts at a clock pin), every SETUPHOLD a
// setup/hold check, and cell delays carry the worst SDF value so a run without read_sdf still sees them. It also writes
// a flat Verilog netlist of the routed cells and a Tcl script for `sta`.
//
// The output is byte for byte what nextpnr_sta.py wrote (tools/sta_prep/compare.sh checks that on any design).
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <sys/stat.h>
#include "../common/minijson.hpp"
#include "../common/toolio.hpp"

namespace sta_prep_tool {

using std::string;
using std::vector;
using minijson::JV;

using Arc = std::pair<string, string>;
using Check = std::tuple<string, string, string>;               // pin, reference pin, reference edge
using Slack = std::pair<double, double>;                         // setup, hold

[[noreturn]] static void die(const string& m) { throw std::runtime_error(m); }

// nextpnr's SDF names the BRAM read clocks by their logical pin; the cell ports are the halves
static string pin_alias(const string& type, const string& pin) {
    if (type == "RAMB36E1_RAMB36E1" && pin == "CLKARDCLK") return "CLKARDCLKL";
    if (type == "RAMB36E1_RAMB36E1" && pin == "CLKBWRCLK") return "CLKBWRCLKL";
    return pin;
}
static const std::pair<const char*, const char*> kAliases[] = {{"CLKARDCLK", "CLKARDCLKL"}, {"CLKBWRCLK", "CLKBWRCLKL"}};

static bool is_word(char c) { return isalnum((unsigned char)c) || c == '_'; }
static bool is_ws(char c) { return isspace((unsigned char)c) != 0; }
static string strip(const string& s) {
    size_t a = 0, b = s.size();
    while (a < b && is_ws(s[a])) a++;
    while (b > a && is_ws(s[b - 1])) b--;
    return s.substr(a, b - a);
}
static bool vid_plain(const string& n) {
    if (n.empty() || !(isalpha((unsigned char)n[0]) || n[0] == '_')) return false;
    for (char c : n) if (!(isalnum((unsigned char)c) || c == '_')) return false;
    return true;
}
static string vid(const string& n) { return vid_plain(n) ? n : "\\" + n + " "; }

static double triple_max(const string& t) {                      // ps -> ns
    double best = 0;
    bool any = false;
    size_t i = 0;
    for (;;) {
        size_t j = t.find(':', i);
        string part = t.substr(i, j == string::npos ? string::npos : j - i);
        if (!part.empty()) {
            double v = strtod(part.c_str(), nullptr);
            if (!any || v > best) best = v;
            any = true;
        }
        if (j == string::npos) break;
        i = j + 1;
    }
    if (!any) die("empty SDF delay triple '" + t + "'");
    return best / 1000.0;
}
static bool triple_chars(char c) { return isdigit((unsigned char)c) || c == '-' || c == '.' || c == ':'; }

// ---------------------------------------------------------------- SDF
struct Sdf {
    std::map<string, std::map<Arc, double>> arcs;                // variant -> (from, to) -> max ns
    std::map<string, std::map<Check, Slack>> checks;
    std::map<string, string> base;                               // variant -> physical type
    std::unordered_map<string, string> inst_variant;
};

// the text of  CELLTYPE "..."  and  (INSTANCE ...)  in a cell body
static bool find_celltype(const string& b, string& t) {
    size_t p = b.find("CELLTYPE \"");
    while (p != string::npos) {
        size_t s = p + 10, e = b.find('"', s);
        if (e != string::npos && e > s) { t = b.substr(s, e - s); return true; }
        p = b.find("CELLTYPE \"", p + 1);
    }
    return false;
}
static bool find_instance(const string& b, string& g) {
    size_t p = b.find("(INSTANCE ");
    if (p == string::npos) return false;
    size_t s = p + 10, e = b.find(')', s);
    if (e == string::npos) return false;
    g = b.substr(s, e - s);
    return true;
}

// IOPATH (\S+) (\S+) \(([-\d.:]+)\)
static bool match_iopath(const string& b, size_t p, string& a, string& c, string& d, size_t& end) {
    size_t i = p + 7, n = b.size();
    size_t s1 = i;
    while (i < n && !is_ws(b[i])) i++;
    if (i == s1 || i >= n || b[i] != ' ') return false;
    a = b.substr(s1, i - s1);
    i++;
    size_t s2 = i;
    while (i < n && !is_ws(b[i])) i++;
    if (i == s2 || i + 1 >= n || b[i] != ' ' || b[i + 1] != '(') return false;
    c = b.substr(s2, i - s2);
    i += 2;
    size_t s3 = i;
    while (i < n && triple_chars(b[i])) i++;
    if (i == s3 || i >= n || b[i] != ')') return false;
    d = b.substr(s3, i - s3);
    end = i + 1;
    return true;
}

// SETUPHOLD \((?:posedge|negedge) (\S+?)\) \((posedge|negedge) (\S+?)\) \(([-\d.:]+)\) \(([-\d.:]+)\)
static bool edge_word(const string& b, size_t i, size_t& len) {
    if (b.compare(i, 7, "posedge") == 0 || b.compare(i, 7, "negedge") == 0) { len = 7; return true; }
    return false;
}
static bool match_setuphold(const string& b, size_t p, string& pin, string& edge, string& ref, string& su, string& ho, size_t& end) {
    size_t n = b.size(), i = p + 10, l;                          // after "SETUPHOLD "
    if (i >= n || b[i] != '(') return false;
    i++;
    if (!edge_word(b, i, l)) return false;
    i += l;
    if (i >= n || b[i] != ' ') return false;
    i++;
    for (size_t k = i + 1; k <= n && !is_ws(b[k - 1]); k++) {      // (\S+?) shortest first
        if (k >= n || b[k] != ')') continue;
        size_t j = k;
        if (b.compare(j, 3, ") (") != 0) continue;
        j += 3;
        if (!edge_word(b, j, l)) continue;
        string e2 = b.substr(j, l);
        j += l;
        if (j >= n || b[j] != ' ') continue;
        j++;
        for (size_t m = j + 1; m <= n && !is_ws(b[m - 1]); m++) {
            if (m >= n || b[m] != ')') continue;
            size_t q = m;
            if (b.compare(q, 3, ") (") != 0) continue;
            q += 3;
            size_t s1 = q;
            while (q < n && triple_chars(b[q])) q++;
            if (q == s1 || b.compare(q, 3, ") (") != 0) continue;
            string t1 = b.substr(s1, q - s1);
            q += 3;
            size_t s2 = q;
            while (q < n && triple_chars(b[q])) q++;
            if (q == s2 || q >= n || b[q] != ')') continue;
            pin = b.substr(i, k - i);
            edge = e2;
            ref = b.substr(j, m - j);
            su = t1;
            ho = b.substr(s2, q - s2);
            end = q + 1;
            return true;
        }
    }
    return false;
}

static const string kCellSep = "\n  (CELL\n";

static void parse_sdf(const string& text, Sdf& out) {
    // each distinct set of IOPATH/SETUPHOLD pins becomes its own Liberty cell, so an instance only has the arcs nextpnr
    // gave it (a LUT using A1-A3 must not grow false A4-A6 -> O5 arcs from another instance)
    std::map<std::tuple<string, std::set<Arc>, std::set<Check>>, string> sig_name;
    std::map<string, int> per_type;
    size_t pos = 0;
    bool first = true;
    for (;;) {
        size_t nx = text.find(kCellSep, pos);
        string body = text.substr(pos, nx == string::npos ? string::npos : nx - pos);
        pos = nx == string::npos ? string::npos : nx + kCellSep.size();
        bool last = nx == string::npos;
        if (!first) {
            string t, g;
            if (find_celltype(body, t) && find_instance(body, g) && !strip(g).empty()) {
                string inst = strip(g);
                inst.erase(std::remove(inst.begin(), inst.end(), '\\'), inst.end());
                std::map<Arc, double> ia;
                for (size_t p = body.find("IOPATH "); p != string::npos;) {
                    string a, b, d;
                    size_t e;
                    if (match_iopath(body, p, a, b, d, e)) {
                        a = pin_alias(t, a); b = pin_alias(t, b);
                        double v = triple_max(d);
                        auto it = ia.find({a, b});
                        ia[{a, b}] = it == ia.end() ? std::max(0.0, v) : std::max(it->second, v);
                        p = body.find("IOPATH ", e);
                    } else p = body.find("IOPATH ", p + 1);
                }
                std::map<Check, Slack> ic;
                for (size_t p = body.find("SETUPHOLD "); p != string::npos;) {
                    string pin, edge, ref, su, ho;
                    size_t e;
                    if (match_setuphold(body, p, pin, edge, ref, su, ho, e)) {
                        ref = pin_alias(t, ref);
                        Check k{pin, ref, edge};
                        Slack o{-1e9, -1e9};
                        auto it = ic.find(k);
                        if (it != ic.end()) o = it->second;
                        ic[k] = {std::max(o.first, triple_max(su)), std::max(o.second, triple_max(ho))};
                        p = body.find("SETUPHOLD ", e);
                    } else p = body.find("SETUPHOLD ", p + 1);
                }
                std::set<Arc> ks;
                for (auto& kv : ia) ks.insert(kv.first);
                std::set<Check> cs;
                for (auto& kv : ic) cs.insert(kv.first);
                auto sig = std::make_tuple(t, ks, cs);
                auto sn = sig_name.find(sig);
                if (sn == sig_name.end()) {
                    int n = per_type[t]++;
                    sn = sig_name.emplace(sig, n == 0 ? t : t + "__v" + std::to_string(n)).first;
                }
                const string& v = sn->second;
                out.base[v] = t;
                out.inst_variant[inst] = v;
                for (auto& kv : ia) {
                    auto& cur = out.arcs[v];
                    auto it = cur.find(kv.first);
                    cur[kv.first] = it == cur.end() ? std::max(0.0, kv.second) : std::max(it->second, kv.second);
                }
                for (auto& kv : ic) {
                    auto& cur = out.checks[v];
                    auto it = cur.find(kv.first);
                    Slack o{-1e9, -1e9};
                    if (it != cur.end()) o = it->second;
                    cur[kv.first] = {std::max(o.first, kv.second.first), std::max(o.second, kv.second.second)};
                }
            }
        }
        first = false;
        if (last) break;
    }
}

// \bWORD\b -> REPL
static string replace_word(const string& s, const string& word, const string& repl) {
    string out;
    size_t i = 0;
    while (i < s.size()) {
        size_t p = s.find(word, i);
        if (p == string::npos) break;
        bool lb = p == 0 || !is_word(s[p - 1]);
        bool rb = p + word.size() >= s.size() || !is_word(s[p + word.size()]);
        out.append(s, i, p - i);
        if (lb && rb) out += repl; else out += word;
        i = p + word.size();
    }
    out.append(s, i, string::npos);
    return out;
}

// '/' is SDF's hierarchy divider: escape the ones in an instance name, and all but the pin divider of an interconnect pin
static string slash_sub(const string& p) {
    string r;
    for (size_t i = 0; i < p.size(); i++) {
        if (p[i] == '/' && (i == 0 || p[i - 1] != '\\')) r += "\\/";
        else r += p[i];
    }
    return r;
}
static string path_escape(const string& p, bool keep_last) {
    if (!keep_last) return slash_sub(p);
    size_t k = p.rfind('/');
    if (k == string::npos) return p;
    return slash_sub(p.substr(0, k)) + "/" + p.substr(k + 1);
}
static string escape_dividers(const string& text) {
    string t1;
    size_t i = 0;
    for (;;) {
        size_t p = text.find("(INSTANCE ", i);
        if (p == string::npos) break;
        size_t s = p + 10, e = text.find(')', s);
        if (e == string::npos || e == s) { t1.append(text, i, p + 1 - i); i = p + 1; continue; }
        t1.append(text, i, p - i);
        t1 += "(INSTANCE " + path_escape(strip(text.substr(s, e - s)), false) + ")";
        i = e + 1;
    }
    t1.append(text, i, string::npos);
    string t2;
    i = 0;
    for (;;) {
        size_t p = t1.find("(INTERCONNECT ", i);
        if (p == string::npos) break;
        size_t s1 = p + 14, a = s1;
        while (a < t1.size() && !is_ws(t1[a])) a++;
        bool ok = a > s1 && a < t1.size() && t1[a] == ' ';
        size_t s2 = a + 1, b = s2;
        if (ok) { while (b < t1.size() && !is_ws(t1[b])) b++; ok = b > s2 && b < t1.size() && t1[b] == ' '; }
        if (!ok) { t2.append(t1, i, p + 1 - i); i = p + 1; continue; }
        t2.append(t1, i, p - i);
        t2 += "(INTERCONNECT " + path_escape(t1.substr(s1, a - s1), true) + " " + path_escape(t1.substr(s2, b - s2), true) + " ";
        i = b + 1;
    }
    t2.append(t1, i, string::npos);
    return t2;
}

// rename the read clocks and give each CELL the variant its instance uses
static string fix_sdf(const string& text, const Sdf& sdf) {
    string out;
    size_t pos = 0;
    bool first = true;
    for (;;) {
        size_t nx = text.find(kCellSep, pos);
        string body = text.substr(pos, nx == string::npos ? string::npos : nx - pos);
        string t, g;
        if (find_celltype(body, t) && find_instance(body, g)) {
            for (auto& al : kAliases)
                if (t == "RAMB36E1_RAMB36E1") body = replace_word(body, al.first, al.second);
            string inst = strip(g);
            inst.erase(std::remove(inst.begin(), inst.end(), '\\'), inst.end());
            auto it = sdf.inst_variant.find(inst);
            const string& v = it == sdf.inst_variant.end() ? t : it->second;
            string from = "CELLTYPE \"" + t + "\"";
            size_t p = body.find(from);
            if (p != string::npos) body.replace(p, from.size(), "CELLTYPE \"" + v + "\"");
        }
        out += body;
        (void)first;
        first = false;
        if (nx == string::npos) break;
        out += kCellSep;
        pos = nx + kCellSep.size();
    }
    return escape_dividers(out);
}

// ---------------------------------------------------------------- Liberty, netlist, Tcl
static string scalar(double v) {
    char b[64];
    snprintf(b, sizeof b, "(scalar) { values(\"%.4f\"); }", v);
    return b;
}

using Ports = std::map<string, string>;

static bool is_clock_name(const string& a) {                   // CK|CLK\w*
    if (a == "CK") return true;
    if (a.compare(0, 3, "CLK") != 0) return false;
    for (size_t i = 3; i < a.size(); i++) if (!is_word(a[i])) return false;
    return true;
}

static void write_lib(const string& path, const std::map<string, Ports>& types, const Sdf& sdf) {
    string out =
        "library(nextpnr_xc7) {\n"
        "  delay_model : table_lookup;\n"
        "  time_unit : \"1ns\"; voltage_unit : \"1V\"; current_unit : \"1mA\";\n"
        "  pulling_resistance_unit : \"1kohm\"; leakage_power_unit : \"1nW\";\n"
        "  capacitive_load_unit (1, pf);\n"
        "  input_threshold_pct_rise : 50; input_threshold_pct_fall : 50;\n"
        "  output_threshold_pct_rise : 50; output_threshold_pct_fall : 50;\n"
        "  slew_lower_threshold_pct_rise : 20; slew_upper_threshold_pct_rise : 80;\n"
        "  slew_lower_threshold_pct_fall : 20; slew_upper_threshold_pct_fall : 80;\n"
        "  nom_voltage : 1.0; nom_temperature : 25; nom_process : 1;\n";
    static const std::map<Arc, double> no_arcs;
    static const std::map<Check, Slack> no_checks;
    for (auto& tk : types) {
        const string& t = tk.first;
        const Ports& dirs = tk.second;
        auto ai = sdf.arcs.find(t);
        auto ci = sdf.checks.find(t);
        const auto& arcs = ai == sdf.arcs.end() ? no_arcs : ai->second;
        const auto& checks = ci == sdf.checks.end() ? no_checks : ci->second;
        std::set<string> clocks;
        for (auto& kv : checks) clocks.insert(std::get<1>(kv.first));
        for (auto& kv : arcs) if (is_clock_name(kv.first.first)) clocks.insert(kv.first.first);
        out += "  cell(\"" + t + "\") {\n";
        for (auto& pd : dirs) {                                  // sorted(dirs)
            const string& p = pd.first;
            const string& d = pd.second;
            if (d != "input" && d != "output" && d != "inout") die("KeyError: direction " + d);
            out += "    pin(\"" + p + "\") {\n";
            out += "      direction : " + d + ";\n";
            if (d != "output") out += "      capacitance : 0;\n";
            if (clocks.count(p)) out += "      clock : true;\n";
            for (auto& kv : arcs) {
                const string& a = kv.first.first;
                if (kv.first.second != p || !dirs.count(a)) continue;
                double v = kv.second;
                out += "      timing() { related_pin : \"" + a + "\";\n";
                out += clocks.count(a) ? "        timing_type : rising_edge;\n" : "        timing_sense : non_unate;\n";
                out += "        cell_rise " + scalar(v) + " cell_fall " + scalar(v) + "\n";
                out += "        rise_transition " + scalar(0) + " fall_transition " + scalar(0) + " }\n";
            }
            for (auto& kv : checks) {
                const string& pin = std::get<0>(kv.first);
                const string& ref = std::get<1>(kv.first);
                if (pin != p || !dirs.count(ref)) continue;
                const char* e = std::get<2>(kv.first) == "posedge" ? "rising" : "falling";
                const std::pair<const char*, double> kinds[] = {{"setup", kv.second.first}, {"hold", kv.second.second}};
                for (auto& k : kinds) {
                    out += string("      timing() { related_pin : \"") + ref + "\"; timing_type : " + k.first + "_" + e + ";\n";
                    out += "        rise_constraint " + scalar(k.second) + " fall_constraint " + scalar(k.second) + " }\n";
                }
            }
            out += "    }\n";
        }
        out += "  }\n";
    }
    out += "}\n";
    std::ofstream(path, std::ios::binary) << out;
}

static string bit_key(const JV& b) {                             // an int net id, or a constant "0"/"1"/"x"/"z"
    if (b.t == JV::Str) return "s" + b.s;
    return "i" + std::to_string((long long)b.n);
}

static void write_netlist(const string& path, const JV& mod, const Sdf& sdf) {
    const JV* netnames = mod.get("netnames");
    std::unordered_map<long long, string> names;
    if (netnames) {
        vector<const std::pair<string, JV>*> order;
        for (auto& kv : netnames->o) order.push_back(&kv);
        std::stable_sort(order.begin(), order.end(), [](auto* x, auto* y) {
            auto key = [](const std::pair<string, JV>* kv) {
                const JV* h = kv->second.get("hide_name");
                return std::make_tuple(kv->first.compare(0, 1, "$") == 0, h ? h->n : 0.0, kv->first.size());
            };
            return key(x) < key(y);
        });
        for (auto* kv : order) {
            const JV* bits = kv->second.get("bits");
            for (size_t i = 0; i < bits->a.size(); i++) {
                const JV& b = bits->a[i];
                if (b.t != JV::Num) continue;
                long long id = (long long)b.n;
                if (!names.count(id)) names[id] = bits->a.size() == 1 ? kv->first : kv->first + "[" + std::to_string(i) + "]";
            }
        }
    }
    std::set<long long> used;
    auto name_of = [&](const JV& b, const string& fallback) -> string {
        if (b.t == JV::Num) { auto it = names.find((long long)b.n); return it != names.end() ? it->second : fallback; }
        return fallback;
    };
    auto net = [&](const JV& b) -> string {
        if (b.t == JV::Str) {
            if (b.s == "0" || b.s == "1") return "1'b" + b.s;
            if (b.s == "x" || b.s == "z") return "1'bx";
            die("unexpected net constant '" + b.s + "'");
        }
        long long id = (long long)b.n;
        used.insert(id);
        auto it = names.find(id);
        return vid(it != names.end() ? it->second : "n" + std::to_string(id));
    };
    vector<string> insts;
    for (auto& cn : mod.get("cells")->o) {
        const JV& c = cn.second;
        vector<const std::pair<string, JV>*> conns;
        for (auto& kv : c.get("connections")->o) conns.push_back(&kv);
        std::sort(conns.begin(), conns.end(), [](auto* x, auto* y) { return x->first < y->first; });
        string cs;
        for (auto* kv : conns) {
            if (kv->second.a.empty()) continue;
            string pn = vid(kv->first);
            while (!pn.empty() && is_ws(pn.back())) pn.pop_back();
            if (!cs.empty()) cs += ", ";
            cs += "." + pn + "(" + net(kv->second.a[0]) + ")";
        }
        auto vi = sdf.inst_variant.find(cn.first);
        string type = vi != sdf.inst_variant.end() ? vi->second : c.get("type")->s;
        insts.push_back("  " + vid(type) + " " + vid(cn.first) + "(" + cs + ");");
    }
    struct P { string name, dir; const JV* bits; };
    vector<P> ports;
    if (const JV* pp = mod.get("ports"))
        for (auto& kv : pp->o) ports.push_back({kv.first, kv.second.get("direction")->s, kv.second.get("bits")});
    string out = "module top(";
    bool firstp = true;
    for (auto& p : ports) {
        if (p.bits->a.empty()) continue;
        if (!firstp) out += ", ";
        firstp = false;
        out += vid(name_of(p.bits->a[0], p.name));
    }
    out += ");\n";
    std::set<string> declared;
    for (auto& p : ports) {
        if (p.bits->a.empty()) continue;
        string n = name_of(p.bits->a[0], p.name);
        out += "  " + p.dir + " " + vid(n) + ";\n";
        declared.insert(n);
    }
    for (long long b : used) {
        auto it = names.find(b);
        string n = it != names.end() ? it->second : "n" + std::to_string(b);
        if (!declared.count(n)) { out += "  wire " + vid(n) + ";\n"; declared.insert(n); }
    }
    for (auto& i : insts) out += i + "\n";
    out += "endmodule\n";
    std::ofstream(path, std::ios::binary) << out;
}

static void mkdir_p(const string& d) {
    for (size_t i = 1; i <= d.size(); i++)
        if (i == d.size() || d[i] == '/') mkdir(d.substr(0, i).c_str(), 0777);
}

static int tool_main(int argc, char** argv) {
    string json_path, sdf_path, log_path, out_dir;
    vector<string> clock_args;
    int paths = 5;
    for (int i = 1; i < argc; i++) {
        string a = argv[i];
        auto val = [&]() -> string { if (i + 1 >= argc) die("missing value for " + a); return argv[++i]; };
        if (a == "--json") json_path = val();
        else if (a == "--sdf") sdf_path = val();
        else if (a == "--log") log_path = val();
        else if (a == "--out") out_dir = val();
        else if (a == "--clock") clock_args.push_back(val());
        else if (a == "--paths") paths = atoi(val().c_str());
        else die("unknown argument " + a);
    }
    if (json_path.empty() || sdf_path.empty() || out_dir.empty())
        die("usage: synthgui --tool sta-prep --json routed.json --sdf routed.sdf [--log pnr.log] --out DIR [--clock PIN=NS ...] [--paths N]");
    mkdir_p(out_dir);
    JV doc = minijson::json_file(json_path);
    const JV* modules = doc.get("modules");
    const JV* mod = modules ? modules->get("top") : nullptr;
    if (!mod) die("no module 'top' in " + json_path);
    string sdf = minijson::read_file(sdf_path);
    Sdf s;
    parse_sdf(sdf, s);

    std::map<string, Ports> ports;                               // physical type -> port -> direction
    for (auto& c : mod->get("cells")->o) {
        Ports& p = ports[c.second.get("type")->s];
        for (auto& pd : c.second.get("port_directions")->o) p[pd.first] = pd.second.s;
    }
    std::map<string, Ports> types = ports;
    for (auto& vt : s.base) {
        auto it = ports.find(vt.second);
        types[vt.first] = it == ports.end() ? Ports() : it->second;
    }
    write_lib(out_dir + "/nextpnr_xc7.lib", types, s);
    write_netlist(out_dir + "/routed.v", *mod, s);
    std::ofstream(out_dir + "/routed.sdf", std::ios::binary) << fix_sdf(sdf, s);

    vector<std::pair<string, string>> clocks;
    for (auto& c : clock_args) {
        size_t e = c.find('=');
        if (e == string::npos || c.find('=', e + 1) != string::npos) die("--clock wants PIN=PERIOD_NS, got '" + c + "'");
        clocks.emplace_back(c.substr(0, e), c.substr(e + 1));
    }
    if (clocks.empty()) {
        // every global buffer that drives something, at the slowest target nextpnr reported
        double mhz = 50.0;
        if (!log_path.empty()) {
            string log = minijson::read_file(log_path);
            double best = 0;
            bool any = false;
            for (size_t p = 0; p < log.size();) {
                size_t a = log.find(" at ", p);
                if (a == string::npos) break;
                bool tag = a >= 4 && (log.compare(a - 4, 4, "PASS") == 0 || log.compare(a - 4, 4, "FAIL") == 0);
                size_t d = a + 4, e = d;
                while (e < log.size() && (isdigit((unsigned char)log[e]) || log[e] == '.')) e++;
                if (tag && e > d && log.compare(e, 4, " MHz") == 0) {
                    double v = strtod(log.substr(d, e - d).c_str(), nullptr);
                    if (!any || v < best) best = v;
                    any = true;
                    p = e + 4;
                } else p = a + 1;
            }
            if (any) mhz = best;
        }
        std::unordered_map<string, int> loads;
        for (auto& c : mod->get("cells")->o) {
            const JV* pd = c.second.get("port_directions");
            for (auto& conn : c.second.get("connections")->o) {
                const JV* d = pd->get(conn.first);
                if (d && d->s == "input") for (auto& b : conn.second.a) loads[bit_key(b)]++;
            }
        }
        for (auto& c : mod->get("cells")->o) {
            if (c.second.get("type")->s != "BUFGCTRL") continue;
            const JV* o = c.second.get("connections")->get("O");
            if (!o || o->a.empty()) die("KeyError: BUFGCTRL without O");
            if (loads[bit_key(o->a[0])] > 0) {
                char per[32];
                snprintf(per, sizeof per, "%.3f", 1000.0 / mhz);
                clocks.emplace_back(c.first + "/O", per);
            }
        }
    }
    string tcl = "read_liberty nextpnr_xc7.lib\nread_verilog routed.v\nlink_design top\n";
    for (auto& c : clocks) {
        string nm = c.first.substr(0, c.first.find('/'));
        for (const char* rm : {"clkgen_", "_bufg"}) {
            size_t p;
            while ((p = nm.find(rm)) != string::npos) nm.erase(p, strlen(rm));
        }
        tcl += "create_clock -name " + nm + " -period " + c.second + " [get_pins {" + c.first + "}]\n";
    }
    tcl += "set_propagated_clock [all_clocks]\nread_sdf routed.sdf\n";
    tcl += "report_checks -path_delay max -group_path_count " + std::to_string(paths) +
           " -fields {fanout} -format full_clock_expanded -digits 3\n";
    tcl += "report_checks -path_delay min -digits 3\nreport_tns\nreport_wns\nreport_clock_min_period\nexit\n";
    std::ofstream(out_dir + "/sta.tcl", std::ios::binary) << tcl;
    string cl;
    for (size_t i = 0; i < clocks.size(); i++) { if (i) cl += ", "; cl += clocks[i].first + "=" + clocks[i].second + "ns"; }
    toolio::out("wrote %s: %zu cell variants, %zu cells, clocks %s\n", out_dir.c_str(), types.size(), mod->get("cells")->o.size(), cl.c_str());
    return 0;
}

}  // namespace sta_prep_tool

int sta_prep_main(int argc, char** argv) {
    try {
        return sta_prep_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    } catch (std::exception& e) {
        toolio::err("sta-prep: %s\n", e.what());
        return 1;
    }
}
