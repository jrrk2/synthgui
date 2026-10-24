// bram-fom -- a figure of merit for a placement's block RAMs (deps/nextpnr/.github/scripts/bram_fom.py in C++).
//
// For each block RAM, its read cone is followed from its data outputs through LUTs, muxes and carries (up to 24 cells,
// nets of fanout 64 or less) to the registers it ends in. Its score is the worst, over those registers r, of
//
//     route(b -> r) + skew(b, r)
//
// with route the measured delay matrix's estimate for the grid offset (nextpnr's -o delay-matrix file, extrapolated at
// its edge rates as nextpnr does), and skew the clock tree's extra insertion delay at the block RAM over a flip-flop at r
// (nextpnr's clock_tree.cc model: 170 ps per clock region row from the BUFGs, 1.7 ps per column from the spine, 430 ps for
// a block RAM clock pin). The mux logic between them is the same in every placement of a netlist, so the score ranks
// placements; it is not a slack.
//
//   synthgui --tool bram-fom --netlist xilinx_vc707.json --tilegrid tilegrid.json --delay-matrix delay-matrix.txt
//       [--budget 3000] [--mark A,B] [--top 5] [--max-worst PS] [--max-p95 PS] NAME=placement.json ...
//
// A nextpnr placement is its -o placement=... JSON; a Vivado one is NAME=vivado:cell_sites.txt ("cell site" lines).
// --max-worst and --max-p95 make it a gate: exit 1 if any placement scores over them.
// Output is what bram_fom.py prints (tools/bram_fom/compare.sh checks that).
#pragma clang fp contract(off)
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <sys/stat.h>
#include "../common/minijson.hpp"
#include "../common/toolio.hpp"

namespace bram_fom_tool {

using std::string;
using std::vector;
using minijson::JV;

[[noreturn]] static void die(const string& m) { throw std::runtime_error(m); }
static bool starts(const string& s, const char* p) { return s.compare(0, strlen(p), p) == 0; }

struct Cell {
    string name, type;
    vector<std::pair<string, vector<long long>>> conns;      // port -> the integer net ids of its bits (strings are skipped)
    std::unordered_map<string, string> dirs;
    bool has_dirs = false;
};

static vector<Cell> load_netlist(const string& path) {
    JV doc = minijson::json_file(path);
    const JV* mods = doc.get("modules");
    if (!mods) die(path + ": no modules");
    const JV* top = nullptr;
    for (auto& m : mods->o) {                                // max by cell count; the first of equals
        const JV* c = m.second.get("cells");
        if (!top || c->o.size() > top->get("cells")->o.size()) top = &m.second;
    }
    if (!top) die(path + ": no modules");
    vector<Cell> cells;
    for (auto& kv : top->get("cells")->o) {
        Cell c;
        c.name = kv.first;
        c.type = kv.second.get("type")->s;
        if (const JV* pd = kv.second.get("port_directions")) {
            c.has_dirs = true;
            for (auto& d : pd->o) c.dirs[d.first] = d.second.s;
        }
        for (auto& cn : kv.second.get("connections")->o) {
            vector<long long> bits;
            for (auto& b : cn.second.a) if (b.t != JV::Str) bits.push_back((long long)b.n);
            c.conns.emplace_back(cn.first, std::move(bits));
        }
        cells.push_back(std::move(c));
    }
    return cells;
}

static std::map<string, std::set<int>> dummy_unused;

// the registers each block RAM's data reaches, as cell indices
static vector<std::pair<int, vector<int>>> read_cones(const vector<Cell>& cells, int depth = 24, size_t max_fanout = 64) {
    std::unordered_map<long long, vector<int>> users;
    for (size_t i = 0; i < cells.size(); i++)
        for (auto& cn : cells[i].conns) {
            auto d = cells[i].dirs.find(cn.first);
            if (d != cells[i].dirs.end() && d->second == "input")
                for (long long b : cn.second) users[b].push_back((int)i);
        }
    auto outputs = [&](int u, bool data_only, vector<int>& out) {
        const Cell& c = cells[u];
        for (auto& cn : c.conns) {
            auto d = c.dirs.find(cn.first);
            if (!c.has_dirs) die("KeyError: port_directions in cell " + c.name);
            if (d == c.dirs.end() || d->second != "output") continue;
            if (data_only && !starts(cn.first, "DO")) continue;
            for (long long b : cn.second) {
                auto& us = users[b];
                if (us.size() <= max_fanout) out.insert(out.end(), us.begin(), us.end());
            }
        }
    };
    auto is_comb = [](const string& t) { return starts(t, "LUT") || starts(t, "MUXF") || starts(t, "CARRY"); };
    auto is_reg = [](const string& t) { return starts(t, "FD"); };
    vector<std::pair<int, vector<int>>> cones;
    for (size_t b = 0; b < cells.size(); b++) {
        if (!starts(cells[b].type, "RAMB")) continue;
        std::set<int> regs;
        std::unordered_set<int> seen;
        vector<int> front;
        outputs((int)b, true, front);
        for (int d = 1; d <= depth; d++) {
            vector<int> nxt;
            for (int u : front) {
                if (!seen.insert(u).second) continue;
                const string& t = cells[u].type;
                if (is_reg(t)) regs.insert(u);
                else if (is_comb(t) && d < depth) outputs(u, false, nxt);
            }
            front = std::move(nxt);
        }
        cones.emplace_back((int)b, vector<int>(regs.begin(), regs.end()));
    }
    return cones;
}

struct DelayMatrix {
    int w = 0, side = 0;
    vector<long long> m;
    double rx = 0, ry = 0;
    long long at(int x, int y) const { return m[(size_t)(y + w) * side + (x + w)]; }
    explicit DelayMatrix(const string& path) {
        std::istringstream in(minijson::read_file(path));
        long long v;
        if (!(in >> w)) die("empty delay matrix " + path);
        side = 2 * w + 1;
        while ((int)m.size() < side * side && (in >> v)) m.push_back(v);
        if ((int)m.size() < side * side) die("short delay matrix " + path);
        const int band = 4;
        double ssx = 0, ssy = 0;
        size_t nx = 0, ny = 0;
        for (int y = -w; y <= w; y++)
            for (int s : {1, -1}) { ssx += (double)(at(s * w, y) - at(s * (w - band), y)) / band; nx++; }
        for (int x = -w; x <= w; x++)
            for (int s : {1, -1}) { ssy += (double)(at(x, s * w) - at(x, s * (w - band))) / band; ny++; }
        rx = std::max(0.0, ssx / (double)nx);                 // the sums are exact: every term is a multiple of 0.25
        ry = std::max(0.0, ssy / (double)ny);
    }
    double operator()(int dx, int dy) const {
        int ex = std::max(-w, std::min(w, dx)), ey = std::max(-w, std::min(w, dy));
        return (double)at(ex, ey) + (double)(std::abs(dx) - std::abs(ex)) * rx + (double)(std::abs(dy) - std::abs(ey)) * ry;
    }
};

// nextpnr's fallback when no delay matrix is measured (predictDelay)
struct FormulaDelay {
    double operator()(int dx, int dy) const {
        int x = std::abs(dx), y = std::abs(dy);
        return 1.5 * (double)(30 * std::min(x, 18) + 10 * std::max(x - 18, 0) + 60 * std::min(y, 6) + 20 * std::max(y - 6, 0) + 300);
    }
};

struct ClockTree {
    vector<int> rows;
    int spine = 0;
    double centre = 0;
    explicit ClockTree(const JV& tilegrid) {
        std::set<int> r;
        long long bufg_sum = 0, bufg_n = 0;
        for (auto& kv : tilegrid.o) {
            const string& type = kv.second.get("type")->s;
            int gx = (int)kv.second.get("grid_x")->n, gy = (int)kv.second.get("grid_y")->n;
            if (starts(type, "CLK_HROW_")) { r.insert(gy); spine = gx; }
            if (starts(type, "CLK_BUFG_TOP") || starts(type, "CLK_BUFG_BOT")) { bufg_sum += gy; bufg_n++; }
        }
        if (!bufg_n) die("tilegrid has no CLK_BUFG tiles");
        rows.assign(r.begin(), r.end());
        centre = (double)bufg_sum / (double)bufg_n;
    }
    double operator()(int x, int y, bool bram) const {
        int best = rows.at(0);
        for (int q : rows) if (std::abs(q - y) < std::abs(best - y)) best = q;     // the first of equals, like min()
        double off = (double)best - centre;
        int away = 0;
        for (int q : rows)
            if (((double)q - centre > 0) == (off > 0) && std::fabs((double)q - centre) < std::fabs(off)) away++;
        double v = 170.0 * away + 1.7 * (double)std::abs(x - spine);
        return bram ? v + 430.0 : v;
    }
};

using Placement = std::unordered_map<string, std::pair<int, int>>;

static Placement load_placement(const string& spec, const std::unordered_map<string, std::pair<int, int>>& site_xy) {
    Placement out;
    if (starts(spec, "vivado:")) {
        // Vivado's names keep the netlist's hierarchy and name registers x_reg[i]; the flat netlist's are x_i
        std::ifstream f(spec.substr(7));
        if (!f) die("cannot open " + spec.substr(7));
        string line;
        while (std::getline(f, line)) {
            std::istringstream ls(line);
            string cell, site, extra;
            if (!(ls >> cell >> site) || (ls >> extra)) die("ValueError: need exactly 2 fields in '" + line + "'");
            auto it = site_xy.find(site);
            if (it == site_xy.end()) continue;
            for (auto& ch : cell) if (ch == '/') ch = '_';
            string flat = cell;
            if (flat.size() >= 4 && flat.compare(flat.size() - 4, 4, "_reg") == 0) flat.erase(flat.size() - 4);
            else if (!flat.empty() && flat.back() == ']') {
                size_t lb = flat.rfind('[');
                if (lb != string::npos && lb >= 4 && flat.compare(lb - 4, 4, "_reg") == 0 && lb + 1 < flat.size() - 1) {
                    string digits = flat.substr(lb + 1, flat.size() - lb - 2);
                    if (std::all_of(digits.begin(), digits.end(), [](char c) { return isdigit((unsigned char)c); }))
                        flat = flat.substr(0, lb - 4) + "_" + digits;
                }
            }
            out[flat] = it->second;
            out[flat + "_0"] = it->second;
        }
        return out;
    }
    JV doc = minijson::json_file(spec);
    for (auto& kv : doc.o) {
        const JV* b = kv.second.get("nextpnr_bel");
        string bel = b ? b->s : string();
        // re.match(r"X(\d+)Y(\d+)/", bel)
        if (bel.empty() || bel[0] != 'X') continue;
        size_t i = 1, j = i;
        while (j < bel.size() && isdigit((unsigned char)bel[j])) j++;
        if (j == i || j >= bel.size() || bel[j] != 'Y') continue;
        size_t k = j + 1, l = k;
        while (l < bel.size() && isdigit((unsigned char)bel[l])) l++;
        if (l == k || l >= bel.size() || bel[l] != '/') continue;
        out[kv.first] = {atoi(bel.substr(i, j - i).c_str()), atoi(bel.substr(k, l - k).c_str())};
    }
    return out;
}

static int tool_main(int argc, char** argv) {
    string netlist, tilegrid, matrix, mark;
    double budget = 3000, max_worst = 0, max_p95 = 0;
    bool have_worst = false, have_p95 = false;
    int top_n = 5;
    vector<string> specs;
    for (int i = 1; i < argc; i++) {
        string a = argv[i];
        auto val = [&]() -> string { if (i + 1 >= argc) die("missing value for " + a); return argv[++i]; };
        if (a == "--netlist") netlist = val();
        else if (a == "--tilegrid") tilegrid = val();
        else if (a == "--delay-matrix") matrix = val();
        else if (a == "--budget") budget = strtod(val().c_str(), nullptr);
        else if (a == "--mark") mark = val();
        else if (a == "--top") top_n = atoi(val().c_str());
        else if (a == "--max-worst") { max_worst = strtod(val().c_str(), nullptr); have_worst = true; }
        else if (a == "--max-p95") { max_p95 = strtod(val().c_str(), nullptr); have_p95 = true; }
        else if (a.compare(0, 2, "--") == 0) die("unknown argument " + a);
        else specs.push_back(a);
    }
    if (netlist.empty() || tilegrid.empty() || matrix.empty() || specs.empty())
        die("usage: synthgui --tool bram-fom --netlist N.json --tilegrid T.json --delay-matrix M.txt [--budget PS] [--mark A,B] "
            "[--top N] [--max-worst PS] [--max-p95 PS] NAME=placement.json ...");

    vector<Cell> cells = load_netlist(netlist);
    auto cones = read_cones(cells);
    JV tg = minijson::json_file(tilegrid);
    std::unordered_map<string, std::pair<int, int>> site_xy;
    for (auto& t : tg.o)
        if (const JV* sites = t.second.get("sites"))
            for (auto& s : sites->o) site_xy[s.first] = {(int)t.second.get("grid_x")->n, (int)t.second.get("grid_y")->n};
    struct stat st;
    bool use_formula = matrix == "formula" || stat(matrix.c_str(), &st) != 0 || !S_ISREG(st.st_mode);
    FormulaDelay formula;
    std::unique_ptr<DelayMatrix> dmat;
    if (!use_formula) dmat.reset(new DelayMatrix(matrix));
    auto dm = [&](int dx, int dy) { return use_formula ? formula(dx, dy) : (*dmat)(dx, dy); };
    ClockTree ct(tg);
    if (use_formula) toolio::out("delay model: nextpnr's formula (no delay matrix file)\n");
    vector<string> marks;
    {
        size_t i = 0;
        for (;;) {
            size_t j = mark.find(',', i);
            string m = mark.substr(i, j == string::npos ? string::npos : j - i);
            if (!m.empty()) marks.push_back(m);
            if (j == string::npos) break;
            i = j + 1;
        }
    }

    vector<string> failed;
    toolio::out("%-22s %6s %6s %6s %6s %8s  %s\n", "placement", "worst", "p95", "p50", "over", "unplaced", "marked ranks");
    for (const string& spec : specs) {
        size_t eq = spec.find('=');
        if (eq == string::npos) die("ValueError: placement '" + spec + "' is not NAME=path");
        string name = spec.substr(0, eq), path = spec.substr(eq + 1);
        Placement pl = load_placement(path, site_xy);
        std::unordered_map<string, double> scores;
        vector<string> order;                                 // scored block RAMs, in cone order
        int missing = 0;
        for (auto& cone : cones) {
            const string& b = cells[cone.first].name;
            auto bp = pl.find(b);
            if (bp == pl.end()) { missing++; continue; }
            int bx = bp->second.first, by = bp->second.second;
            bool have = false;
            double worst = 0;
            for (int r : cone.second) {
                auto rp = pl.find(cells[r].name);
                if (rp == pl.end()) continue;
                int rx = rp->second.first, ry = rp->second.second;
                double s = dm(rx - bx, ry - by) + ct(bx, by, true) - ct(rx, ry, false);
                worst = have ? std::max(worst, s) : s;
                have = true;
            }
            if (have) { scores[b] = worst; order.push_back(b); }
        }
        vector<string> ranked = order;
        std::stable_sort(ranked.begin(), ranked.end(), [&](const string& x, const string& y) { return scores[x] > scores[y]; });
        vector<double> v;
        for (auto& b : order) v.push_back(scores[b]);
        std::sort(v.begin(), v.end());
        if (v.empty()) { toolio::out("%-22s no block RAMs\n", name.c_str()); continue; }
        auto p = [&](double q) { return v[std::min(v.size() - 1, (size_t)(q * (double)v.size()))]; };
        int over = 0;
        for (double s : v) if (s > budget) over++;
        string ranks;
        for (const string& m : marks) {
            if (!scores.count(m)) continue;
            string label = m;
            for (size_t q; (q = label.find("rom_inst_")) != string::npos;) label.erase(q, 9);
            size_t pos = std::find(ranked.begin(), ranked.end(), m) - ranked.begin();
            if (!ranks.empty()) ranks += " ";
            ranks += label + ":#" + std::to_string(pos + 1);
        }
        toolio::out("%-22s %6.0f %6.0f %6.0f %6d %8d  %s\n", name.c_str(), v.back(), p(0.95), p(0.5), over, missing, ranks.c_str());
        for (size_t i = 0; i < ranked.size() && (int)i < top_n; i++) {
            const string& b = ranked[i];
            toolio::out("    %-24s %6.0f  at X%dY%d\n", b.c_str(), scores[b], pl[b].first, pl[b].second);
        }
        char buf[256];
        if (have_worst && v.back() > max_worst) {
            snprintf(buf, sizeof buf, "%s: worst %.0f ps is over %.0f", name.c_str(), v.back(), max_worst);
            failed.push_back(buf);
        }
        if (have_p95 && p(0.95) > max_p95) {
            snprintf(buf, sizeof buf, "%s: p95 %.0f ps is over %.0f", name.c_str(), p(0.95), max_p95);
            failed.push_back(buf);
        }
    }
    for (auto& f : failed) toolio::out("FAIL %s\n", f.c_str());
    return failed.empty() ? 0 : 1;
}

}  // namespace bram_fom_tool

int bram_fom_main(int argc, char** argv) {
    try {
        return bram_fom_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    } catch (std::exception& e) {
        toolio::err("bram-fom: %s\n", e.what());
        return 1;
    }
}
