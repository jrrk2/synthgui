// pr_block_json -- xc7/pr_block_json.py in C++: netlist surgery for a partial-reconfiguration window.  The logic, the messages
// and the output follow the Python (json.dump with indent=1, byte for byte); tools/pr_partial/compare.sh checks that.
//
//   synthgui --tool pr-block-json merge --harness H.json --block B.json --instance at_block --prefix at_block. --out M.json
//     The harness with the instance replaced by the block's cells, named <prefix><name>; the block's port bits become the
//     instance's nets.
//   synthgui --tool pr-block-json window --block B.json --harness H.json --instance at_block --interface harness.pri
//                                 --map window-map.json --prefix at_block. --out W.json [--reserve reserve.txt]
//     The block alone as a top-level design for the window chipdb: each port becomes a PARTPIN_IN (input) or PARTPIN_OUT
//     (output) cell pinned (BEL attribute) to the boundary node the harness build reported for that port's net in its
//     -o pr-interface file, looked up in the window chipdb's --window-map.
#include <cstdint>
#include <exception>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include "../common/pycompat.hpp"
#include "../common/toolio.hpp"

namespace pr_block_json_tool {

using std::string;
using std::vector;
using pycompat::Array;
using pycompat::V;

[[noreturn]] static void die(const string& m) {
    toolio::err("pr_block_json: %s\n", m.c_str());
    throw toolio::Exit{1};
}

// a.get("top") not in (None, 0, "0", "0...0")
static bool is_top(const V* a) {
    if (!a) return false;
    switch (a->type()) {
        case V::Null: return false;
        case V::Int: case V::Bool: return a->i() != 0;
        case V::Float: return a->d() != 0;
        case V::Str: return a->s() != "0" && a->s() != "00000000000000000000000000000000";
        default: return true;
    }
}
static const string& top_module_name(const V& j) {
    const pycompat::Object& mods = j.at("modules").o();
    for (const auto& kv : mods.items()) {
        const V* attrs = kv.second.o().find("attributes");
        if (attrs && is_top(attrs->o().find("top"))) return kv.first;
    }
    if (mods.empty()) die("max() of no modules");
    const string* best = nullptr;
    size_t most = 0;
    for (const auto& kv : mods.items()) {
        size_t n = kv.second.at("cells").o().size();
        if (!best || n > most) { best = &kv.first; most = n; }
    }
    return *best;
}

static void scan_bits(const Array& bits, int64_t& m) {
    for (const V& b : bits) if (b.is_int() && b.i() > m) m = b.i();
}
static int64_t max_bit(const V& m) {
    int64_t r = 0;
    for (const auto& p : m.at("ports").o().items()) scan_bits(p.second.at("bits").a(), r);
    for (const auto& c : m.at("cells").o().items())
        for (const auto& bits : c.second.at("connections").o().items()) scan_bits(bits.second.a(), r);
    for (const auto& n : m.at("netnames").o().items()) scan_bits(n.second.at("bits").a(), r);
    return r;
}

static int cmd_merge(const pycompat::Args& a) {
    V hj = pycompat::load(a.get("--harness"));
    V bj = pycompat::load(a.get("--block"));
    const string hname = top_module_name(hj), bname = top_module_name(bj);
    V& H = hj.at("modules").at(hname);
    const V& B = bj.at("modules").at(bname);
    const string instance = a.get("--instance"), prefix = a.get("--prefix");
    if (!H.at("cells").o().find(instance)) {
        vector<string> same;
        for (const auto& c : H.at("cells").o().items())
            if (same.size() < 5 && c.second.at("type").s() == bname) same.push_back(c.first);
        die("harness has no cell " + instance + "; cells of type " + bname + ": " + pycompat::repr_list(same));
    }
    const int64_t offset = max_bit(H) + 1;
    std::unordered_map<int64_t, V> bitmap;
    std::unordered_set<int64_t> port_bits;
    {
        const V& inst = H.at("cells").at(instance);
        for (const auto& port : B.at("ports").o().items()) {
            const V* hb = inst.at("connections").o().find(port.first);
            if (!hb) die("instance " + instance + " has no connection for block port " + port.first);
            const Array& hbits = hb->a();
            const Array& bbits = port.second.at("bits").a();
            if (hbits.size() != bbits.size())
                die("port " + port.first + ": " + std::to_string(bbits.size()) + " bits in the block, " + std::to_string(hbits.size()) + " on the instance");
            for (size_t i = 0; i < bbits.size(); i++)
                if (bbits[i].is_int()) {                            // a string bit (a constant) is never looked up
                    bitmap[bbits[i].i()] = hbits[i];
                    port_bits.insert(bbits[i].i());
                }
        }
    }
    auto remap = [&](const Array& bits) {
        V out = V::array();
        out.a().reserve(bits.size());
        for (const V& b : bits) {
            if (!b.is_int()) { out.a().push_back(b); continue; }
            auto it = bitmap.find(b.i());
            if (it != bitmap.end()) out.a().push_back(it->second);
            else out.a().push_back(V(b.i() + offset));
        }
        return out;
    };
    pycompat::Object& hcells = H.at("cells").o();
    pycompat::Object& hnets = H.at("netnames").o();
    hcells.erase(instance);
    for (const auto& c : B.at("cells").o().items()) {
        V nc = c.second;
        V conn = V::object();
        for (const auto& p : c.second.at("connections").o().items()) conn.o().set(p.first, remap(p.second.a()));
        nc.at("connections") = std::move(conn);
        hcells.set(prefix + c.first, std::move(nc));
    }
    for (const auto& n : B.at("netnames").o().items()) {
        const Array& bits = n.second.at("bits").a();
        bool port_net = true;                                       // a port net keeps the harness's name
        for (const V& b : bits) if (b.is_int() && !port_bits.count(b.i())) { port_net = false; break; }
        if (port_net) continue;
        V nn = n.second;
        nn.at("bits") = remap(bits);
        hnets.set(prefix + n.first, std::move(nn));
    }
    pycompat::dump_file(hj, a.get("--out"), 1);
    toolio::out("merge: %zu cells and %zu nets of %s added as %s*, instance %s removed, bits offset by %lld -> %s\n",
                B.at("cells").o().size(), B.at("netnames").o().size(), bname.c_str(), prefix.c_str(), instance.c_str(),
                (long long)offset, a.get("--out").c_str());
    return 0;
}

// net -> (dir, wire), in file order, duplicates dropped
struct Interface {
    vector<std::pair<string, vector<std::pair<string, string>>>> nets;
    std::unordered_map<string, size_t> index;
};
static Interface read_interface(const string& path) {
    Interface r;
    std::unordered_set<string> seen;
    string text = pycompat::read_file(path);
    pycompat::for_each_line(text, [&](std::string_view line) {
        size_t t1 = line.find('\t');
        if (t1 == std::string_view::npos) return;
        size_t t2 = line.find('\t', t1 + 1);
        if (t2 == std::string_view::npos || line.find('\t', t2 + 1) != std::string_view::npos) return;
        if (line.compare(0, 8, "$PACKER_") == 0) return;
        if (!seen.insert(string(line)).second) return;
        string net(line.substr(0, t1));
        auto it = r.index.find(net);
        size_t i;
        if (it == r.index.end()) { i = r.nets.size(); r.index.emplace(net, i); r.nets.emplace_back(net, vector<std::pair<string, string>>()); }
        else i = it->second;
        r.nets[i].second.emplace_back(string(line.substr(t1 + 1, t2 - t1 - 1)), string(line.substr(t2 + 1)));
    });
    return r;
}

static int cmd_window(const pycompat::Args& a) {
    V bj = pycompat::load(a.get("--block"));
    const string bname = top_module_name(bj);
    V& B = bj.at("modules").at(bname);
    V hj = pycompat::load(a.get("--harness"));
    const string hname = top_module_name(hj);
    const V& H = hj.at("modules").at(hname);
    const string instance = a.get("--instance"), prefix = a.get("--prefix"), out_path = a.get("--out"), reserve = a.get("--reserve");
    const V& inst = H.at("cells").at(instance);
    Interface interface = read_interface(a.get("--interface"));
    V wmap = pycompat::load(a.get("--map"));
    const pycompat::Object& wires = wmap.at("wires").o();
    const V& nodes = wmap.at("nodes");
    // harness net names per bit (an integer bit and a string bit are different keys)
    std::unordered_map<int64_t, vector<const string*>> names_of_int;
    std::unordered_map<string, vector<const string*>> names_of_str;
    for (const auto& n : H.at("netnames").o().items())
        for (const V& b : n.second.at("bits").a()) {
            if (b.is_int()) names_of_int[b.i()].push_back(&n.first);
            else names_of_str[b.s()].push_back(&n.first);
        }
    V W = V::object();
    {
        V attrs = V::object();
        attrs.o().set("top", "00000000000000000000000000000001");
        W.o().set("attributes", std::move(attrs));
        W.o().set("ports", V::object());
        W.o().set("cells", V::object());
        W.o().set("netnames", V::object());
    }
    pycompat::Object& wcells = W.at("cells").o();
    pycompat::Object& wnets = W.at("netnames").o();
    for (const auto& c : B.at("cells").o().items()) wcells.set(prefix + c.first, c.second);
    for (const auto& n : B.at("netnames").o().items()) wnets.set(prefix + n.first, n.second);
    size_t pinned = 0;
    static const vector<const string*> none;
    for (const auto& port : B.at("ports").o().items()) {
        const string& pname = port.first;
        const Array& pbits = port.second.at("bits").a();
        const Array& hbits = inst.at("connections").at(pname).a();
        for (size_t i = 0; i < pbits.size() && i < hbits.size(); i++) {
            const V& bb = pbits[i];
            const V& hb = hbits[i];
            const vector<const string*>* cand = &none;
            if (hb.is_int()) { auto it = names_of_int.find(hb.i()); if (it != names_of_int.end()) cand = &it->second; }
            else { auto it = names_of_str.find(hb.s()); if (it != names_of_str.end()) cand = &it->second; }
            const string label = pbits.size() == 1 ? pname : pname + "[" + std::to_string(i) + "]";
            const string* net = nullptr;
            const vector<std::pair<string, string>>* crossings = nullptr;
            for (const string* n : *cand) {
                auto it = interface.index.find(*n);
                if (it != interface.index.end()) { net = n; crossings = &interface.nets[it->second].second; break; }
            }
            if (!net) {
                vector<string> names;
                for (const string* n : *cand) names.push_back(*n);
                die("port " + label + ": none of the harness nets " + pycompat::repr_list(names) + " is in the interface file");
            }
            const bool is_in = port.second.at("direction").s() == "input";
            const string want = is_in ? "in" : "out";
            vector<const string*> xs;
            for (const auto& x : *crossings) if (x.first == want) xs.push_back(&x.second);
            if (xs.empty()) die("port " + label + ": net " + *net + " has no '" + want + "' crossing");
            if (xs.size() > 1)
                toolio::out("port %s: net %s crosses %s %zu times, pinned to the first (%s); the others are reserved\n",
                            label.c_str(), net->c_str(), want.c_str(), xs.size(), xs[0]->c_str());
            const V* canon = wires.find(*xs[0]);
            if (!canon || canon->type() == V::Null) die("port " + label + ": wire " + *xs[0] + " is not a boundary node of the window map");
            const V& node = nodes.at(canon->s());
            const string& bel = node.at(is_in ? "in" : "out").s();
            {
                V cell = V::object();
                cell.o().set("hide_name", 0);
                cell.o().set("type", is_in ? "PARTPIN_IN" : "PARTPIN_OUT");
                cell.o().set("parameters", V::object());
                V attrs = V::object();
                attrs.o().set("BEL", bel);
                cell.o().set("attributes", std::move(attrs));
                V dirs = V::object();
                dirs.o().set(is_in ? "O" : "I", is_in ? "output" : "input");
                cell.o().set("port_directions", std::move(dirs));
                V conn = V::object();
                V one = V::array();
                one.a().push_back(bb);
                conn.o().set(is_in ? "O" : "I", one);
                cell.o().set("connections", std::move(conn));
                wcells.set("pp_" + label, std::move(cell));
                V nn = V::object();
                nn.o().set("hide_name", 0);
                nn.o().set("bits", std::move(one));
                nn.o().set("attributes", V::object());
                wnets.set(prefix + label, std::move(nn));
            }
            toolio::out("port %-10s %-3s net %-40s node %s -> %s\n", label.c_str(), want.c_str(), net->c_str(), canon->s().c_str(), bel.c_str());
            pinned++;
        }
    }
    {
        V out = V::object();
        out.o().set("creator", "pr_block_json.py window");
        V mods = V::object();
        mods.o().set("window", W);
        out.o().set("modules", std::move(mods));
        pycompat::dump_file(out, out_path, 1);
    }
    // every node the static design drives into the window that no partition pin took, re-entries included (they float once
    // the window is replaced): reserved, so the window build never routes through such a wire
    if (!reserve.empty()) {
        std::unordered_set<string> taken, listed;
        for (const auto& c : wcells.items())
            if (c.second.at("type").s() == "PARTPIN_IN") taken.insert(c.second.at("attributes").at("BEL").s());
        string text = "# nodes the static design drives into the window, beyond the partition pins\n";
        size_t reserved = 0, unknown = 0;
        for (const auto& net : interface.nets)
            for (const auto& x : net.second) {
                if (x.first != "in" && x.first != "reentry") continue;
                const V* canon = wires.find(x.second);
                if (!canon || canon->type() == V::Null) { unknown++; continue; }
                const string& bel = nodes.at(canon->s()).at("in").s();
                if (!taken.count(bel) && listed.insert(bel).second) { text += bel; text += '\n'; reserved++; }
            }
        pycompat::write_file(reserve, text);
        string tail = unknown ? " (" + std::to_string(unknown) + " crossing wires not in the window map)" : "";
        toolio::out("window: %zu driven nodes reserved -> %s%s\n", reserved, reserve.c_str(), tail.c_str());
    }
    toolio::out("window: %zu cells, %zu partition pins -> %s\n", wcells.size(), pinned, out_path.c_str());
    return 0;
}

static const char* const USAGE =
    "usage: pr-block-json merge --harness H.json --block B.json --instance NAME --prefix PREFIX --out M.json\n"
    "       pr-block-json window --block B.json --harness H.json --instance NAME --interface FILE --map window-map.json\n"
    "                            --prefix PREFIX --out W.json [--reserve FILE]\n";

int tool_main(int argc, char** argv) {
    try {
        pycompat::Args a = pycompat::parse_args(argc, argv, {"--harness", "--block", "--instance", "--prefix", "--out", "--interface", "--map", "--reserve"});
        if (a.help) { toolio::out("%s", USAGE); return 0; }
        const string cmd = a.pos.empty() ? string() : a.pos[0];
        vector<string> need = {"--harness", "--block", "--instance", "--prefix", "--out"};
        if (cmd == "window") { need.push_back("--interface"); need.push_back("--map"); }
        bool ok = a.pos.size() == 1 && (cmd == "merge" || cmd == "window");
        for (const string& n : need) if (!a.has(n)) ok = false;
        if (!ok) { toolio::err("%s", USAGE); return 2; }
        return cmd == "merge" ? cmd_merge(a) : cmd_window(a);
    } catch (std::exception& e) {
        toolio::err("pr_block_json: %s\n", e.what());
        return 1;
    }
}

}  // namespace pr_block_json_tool

int pr_block_json_main(int argc, char** argv) {
    try {
        return pr_block_json_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    }
}
