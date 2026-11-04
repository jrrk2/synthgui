// at_gen -- xc7/at_gen.py in C++: generate an at-speed test block as a yosys-style JSON netlist for nextpnr.  The cells, the
// nets, the bit numbers and the file (json.dump with indent=1) are the Python's byte for byte; tools/pr_partial/compare.sh
// checks that.
//
//   synthgui --tool at-gen --depths 0,1,2,4,8 out.json
//
// The block has the seven-port interface of at_block.v (clk_l, clk_c, rst, run, ld, sh_en, sh_out) and the same protocol, with
// NPATHS paths under test instead of one.  It is written as cells (FDRE, LUTn) rather than Verilog so that no synthesiser can
// restructure a path: a path of depth d is exactly d LUT2 stages, each XORing the previous stage with a bit of the results
// shift chain (0 while a test runs, so the capture value equals the launch value and the error flag reads directly).
//
// Per path i:
//   lq[i]  FDRE clk_l, CE = run, D = b (the LFSR launch bit)
//   s0 = lq[i]; s_k = s_{k-1} ^ sh[(7 i + k) mod 16 NPATHS]   (k = 1..depth)
//   rq[i]  FDRE clk_c, D = lq[i]      (the reference: the shortest path)
//   cq[i]  FDRE clk_c, D = s_depth    (the capture)
//   e[i]   FDRE clk_c, D = rq[i] ^ cq[i]
//   cnt[i] 16-bit LFSR counter in clk_c, CE = run_c & e[i], set to 1 by rst_c; the host decodes its state to a count
//          (lfsr16.hpp, at-decode).
// The shift chain (clk_l) loads {cnt[0], cnt[1], ...} on ld (path 0 at the output end, MSB first), shifts on sh_en, clears on rst.
#include <cstdint>
#include <exception>
#include <functional>
#include <map>
#include <string>
#include <vector>
#include "../common/pycompat.hpp"
#include "../common/toolio.hpp"
#include "lfsr16.hpp"

namespace at_gen_tool {

using std::string;
using std::vector;
using pycompat::V;

static string fmt(const char* base, int a) { return base + std::to_string(a); }
static string idx(const char* base, int i) { return base + ("[" + std::to_string(i) + "]"); }

static V bits1(V b) { V a = V::array(); a.a().push_back(std::move(b)); return a; }

struct Gen {
    int n = 2;                                                  // 0 and 1 are the constants' spellings in yosys JSON
    V names = V::object();
    V cells = V::object();

    int net(const string& name = string()) {
        int b = n++;
        if (!name.empty()) names.o().set(name, b);
        return b;
    }
    // FDRE; a D, CE or R of "0"/"1" is a constant
    void ff(const string& name, int clk, int d, int q, const V& rst = V("0")) {
        V c = V::object();
        c.o().set("hide_name", 0);
        c.o().set("type", "FDRE");
        V params = V::object();
        params.o().set("INIT", "0");
        c.o().set("parameters", std::move(params));
        c.o().set("attributes", V::object());
        V pd = V::object();
        for (const char* p : {"C", "CE", "D", "R"}) pd.o().set(p, "input");
        pd.o().set("Q", "output");
        c.o().set("port_directions", std::move(pd));
        V conn = V::object();
        conn.o().set("C", bits1(clk));
        conn.o().set("CE", bits1("1"));
        conn.o().set("D", bits1(d));
        conn.o().set("R", bits1(rst));
        conn.o().set("Q", bits1(q));
        c.o().set("connections", std::move(conn));
        cells.o().set(name, std::move(c));
    }
    void lut(const string& name, const vector<V>& inputs, const std::function<int(unsigned)>& fn, int out) {
        const int nin = (int)inputs.size();
        // yosys spells INIT MSB first, bit i of INIT is the output for inputs I(n-1)..I0 = i
        string init;
        for (int i = (1 << nin) - 1; i >= 0; i--) init += fn((unsigned)i) ? '1' : '0';
        V c = V::object();
        c.o().set("hide_name", 0);
        c.o().set("type", fmt("LUT", nin));
        V params = V::object();
        params.o().set("INIT", std::move(init));
        c.o().set("parameters", std::move(params));
        c.o().set("attributes", V::object());
        V pd = V::object();
        V conn = V::object();
        for (int i = 0; i < nin; i++) {
            pd.o().set(fmt("I", i), "input");
            conn.o().set(fmt("I", i), bits1(inputs[(size_t)i]));
        }
        pd.o().set("O", "output");
        conn.o().set("O", bits1(out));
        c.o().set("port_directions", std::move(pd));
        c.o().set("connections", std::move(conn));
        cells.o().set(name, std::move(c));
    }
};

static int parity(unsigned i) {
    int p = 0;
    for (; i; i &= i - 1) p ^= 1;
    return p;
}

static V build(const vector<int>& depths) {
    Gen g;
    const int npaths = (int)depths.size();
    const int clk_l = g.net("clk_l"), clk_c = g.net("clk_c");
    const int rst = g.net("rst"), run = g.net("run"), ld = g.net("ld"), sh_en = g.net("sh_en"), sh_out = g.net("sh_out");

    // launch LFSR: x^32 + x^22 + x^2 + x + 1, seed 0xACE12357, advances while run, set by rst
    const uint32_t seed = 0xACE12357u;
    vector<int> lfsr;
    for (int i = 0; i < 32; i++) lfsr.push_back(g.net(idx("lfsr", i)));
    const int fb = g.net("lfsr_fb");
    g.lut("lfsr_fb", {lfsr[31], lfsr[21], lfsr[1], lfsr[0]}, parity, fb);
    for (int i = 0; i < 32; i++) {
        const int d = i == 0 ? fb : lfsr[(size_t)i - 1];
        const int dr = g.net(fmt("lfsr_d", i));
        if ((seed >> i) & 1) {
            // rst ? 1 : (run ? d : q)   with I0 = q, I1 = d, I2 = run, I3 = rst
            g.lut(fmt("lfsr_mux_", i), {lfsr[(size_t)i], d, run, rst}, [](unsigned x) -> int { return x & 8 ? 1 : x & 4 ? (x >> 1) & 1 : x & 1; }, dr);
            g.ff(fmt("lfsr_", i), clk_l, dr, lfsr[(size_t)i]);
        } else {
            // run ? d : q, and the flop resets on rst
            g.lut(fmt("lfsr_mux_", i), {lfsr[(size_t)i], d, run}, [](unsigned x) -> int { return x & 4 ? (x >> 1) & 1 : x & 1; }, dr);
            g.ff(fmt("lfsr_", i), clk_l, dr, lfsr[(size_t)i], rst);
        }
    }
    const int b = lfsr[0];

    // run and rst into the capture domain
    const int run_c0 = g.net("run_c0"), run_c = g.net("run_c"), rst_c0 = g.net("rst_c0"), rst_c = g.net("rst_c");
    g.ff("run_c0", clk_c, run, run_c0);
    g.ff("run_c", clk_c, run_c0, run_c);
    g.ff("rst_c0", clk_c, rst, rst_c0);
    g.ff("rst_c", clk_c, rst_c0, rst_c);

    const int nsh = 16 * npaths;
    vector<int> sh;
    for (int i = 0; i < nsh; i++) sh.push_back(g.net(idx("sh", i)));
    vector<vector<int>> cnt;
    for (int p = 0; p < npaths; p++) {
        const int depth = depths[(size_t)p];
        const int lq = g.net(idx("lq", p));
        const int lqd = g.net(idx("lqd", p));
        g.lut(fmt("lq_mux_", p), {lq, b, run}, [](unsigned x) -> int { return x & 4 ? (x >> 1) & 1 : x & 1; }, lqd);   // run ? b : lq
        g.ff(fmt("lq_", p), clk_l, lqd, lq);
        int s = lq;
        for (int k = 1; k <= depth; k++) {
            const string name = "path" + std::to_string(p) + "_s" + std::to_string(k);
            const int t = g.net(name);
            g.lut(name, {s, sh[(size_t)((7 * p + k) % nsh)]}, parity, t);
            s = t;
        }
        const int rq = g.net(idx("rq", p)), cq = g.net(idx("cq", p)), e = g.net(idx("e", p));
        g.ff(fmt("rq_", p), clk_c, lq, rq);
        g.ff(fmt("cq_", p), clk_c, s, cq);
        const int ed = g.net(idx("ed", p));
        g.lut(fmt("e_lut_", p), {rq, cq}, parity, ed);
        g.ff(fmt("e_", p), clk_c, ed, e);
        // 16-bit LFSR counter x^16 + x^14 + x^13 + x^11, state 1 after rst, steps on run_c & e
        const string pre = fmt("cnt", p);
        vector<int> c;
        for (int i = 0; i < 16; i++) c.push_back(g.net(pre + "[" + std::to_string(i) + "]"));
        const int cfb = g.net(pre + "_fb");
        g.lut(pre + "_fb", {c[15], c[13], c[12], c[10]}, parity, cfb);
        for (int i = 0; i < 16; i++) {
            const int d = i == 0 ? cfb : c[(size_t)i - 1];
            const int d1 = g.net(pre + "_d" + std::to_string(i));
            const string mux = pre + "_mux" + std::to_string(i), flop = pre + "_" + std::to_string(i);
            if (i == 0) {
                // rst_c ? 1 : ((run_c & e) ? d : q)   with I0 = q, I1 = d, I2 = run_c, I3 = e, I4 = rst_c
                g.lut(mux, {c[0], d, run_c, e, rst_c}, [](unsigned x) -> int { return x & 16 ? 1 : (x & 12) == 12 ? (x >> 1) & 1 : x & 1; }, d1);
                g.ff(flop, clk_c, d1, c[0]);
            } else {
                // (run_c & e) ? d : q, reset on rst_c
                g.lut(mux, {c[(size_t)i], d, run_c, e}, [](unsigned x) -> int { return (x & 12) == 12 ? (x >> 1) & 1 : x & 1; }, d1);
                g.ff(flop, clk_c, d1, c[(size_t)i], rst_c);
            }
        }
        cnt.push_back(c);
    }

    // results shift chain: sh[nsh-1] is sh_out; on ld, path 0's counter lands in the top 16 bits (MSB at the top), path 1 below
    // it, ...; shifts up by one on sh_en; clears on rst.  No clock-enable nets anywhere: the enables are folded into the D muxes
    // (the hold-fix pass double-buffers two flops sharing a slice CE mux)
    for (int j = 0; j < nsh; j++) {
        const int p = (nsh - 1 - j) / 16;
        const int i = j - (nsh - 16 * (p + 1));
        const int src = cnt[(size_t)p][(size_t)i];
        const V prev = j > 0 ? V(sh[(size_t)j - 1]) : V("0");
        const int d = g.net(idx("shd", j));
        // ld ? src : (sh_en ? prev : q)   with I0 = q, I1 = prev, I2 = src, I3 = sh_en, I4 = ld
        g.lut(fmt("sh_mux_", j), {sh[(size_t)j], prev, src, sh_en, ld},
              [](unsigned x) -> int { return x & 16 ? (x >> 2) & 1 : x & 8 ? (x >> 1) & 1 : x & 1; }, d);
        g.ff(fmt("sh_", j), clk_l, d, sh[(size_t)j], rst);
    }
    g.lut("sh_out_buf", {sh[(size_t)nsh - 1]}, [](unsigned x) -> int { return x & 1; }, sh_out);

    V ports = V::object();
    auto port = [&](const char* name, const char* dir, int bit) {
        V p = V::object();
        p.o().set("direction", dir);
        p.o().set("bits", bits1(bit));
        ports.o().set(name, std::move(p));
    };
    port("clk_l", "input", clk_l);
    port("clk_c", "input", clk_c);
    port("rst", "input", rst);
    port("run", "input", run);
    port("ld", "input", ld);
    port("sh_en", "input", sh_en);
    port("sh_out", "output", sh_out);
    V netnames = V::object();
    for (const auto& kv : g.names.o().items()) {
        V nn = V::object();
        nn.o().set("hide_name", 0);
        nn.o().set("bits", bits1(kv.second));
        nn.o().set("attributes", V::object());
        netnames.o().set(kv.first, std::move(nn));
    }
    V attrs = V::object();
    attrs.o().set("top", "00000000000000000000000000000001");
    V mod = V::object();
    mod.o().set("attributes", std::move(attrs));
    mod.o().set("ports", std::move(ports));
    mod.o().set("cells", std::move(g.cells));
    mod.o().set("netnames", std::move(netnames));
    V mods = V::object();
    mods.o().set("at_block", std::move(mod));
    V j = V::object();
    j.o().set("creator", "at_gen.py");
    j.o().set("modules", std::move(mods));
    return j;
}

int tool_main(int argc, char** argv) {
    try {
        pycompat::Args a = pycompat::parse_args(argc, argv, {"--depths"});
        if (a.help || !a.has("--depths") || a.pos.size() != 1) {
            toolio::err("usage: at-gen --depths 0,1,2,4,8 out.json\n");
            return a.help ? 0 : 2;
        }
        vector<int> depths;
        const string text = a.get("--depths");
        size_t i = 0;
        for (;;) {
            size_t j = text.find(',', i);
            depths.push_back((int)pycompat::to_int(std::string_view(text).substr(i, j == string::npos ? string::npos : j - i), 10));
            if (j == string::npos) break;
            i = j + 1;
        }
        V j = build(depths);
        pycompat::dump_file(j, a.pos[0], 1);
        const pycompat::Object& cells = j.at("modules").at("at_block").at("cells").o();
        std::map<string, int> types;
        for (const auto& c : cells.items()) types[c.second.at("type").s()]++;
        string list;
        for (const auto& kv : types) {
            if (!list.empty()) list += ' ';
            list += kv.first + "=" + std::to_string(kv.second);
        }
        toolio::out("at_gen: %zu paths (depths %s), %zu cells: %s -> %s\n", depths.size(), pycompat::int_list(depths).c_str(), cells.size(), list.c_str(), a.pos[0].c_str());
        return 0;
    } catch (std::exception& e) {
        toolio::err("at_gen: %s\n", e.what());
        return 1;
    }
}

}  // namespace at_gen_tool

int at_gen_main(int argc, char** argv) {
    try {
        return at_gen_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    }
}
