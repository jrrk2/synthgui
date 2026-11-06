// pr_partial -- xc7/pr_partial.py in C++, so a partial-reconfiguration image needs no Python; the logic, the messages and the
// output follow the Python, and tools/pr_partial/compare.sh checks that byte for byte.
//
//   synthgui --tool pr-partial --tilegrid tilegrid.json --window x0,y0,x1,y1 merge harness.fasm window.fasm merged.fasm
//   synthgui --tool pr-partial --tilegrid tilegrid.json --window x0,y0,x1,y1 extract merged.frames out.icap
//                              [--ref harness.frames] [--idcode 0x03687093] [--frames-out window.frames]
//   synthgui --tool pr-partial check merged.fasm --map window-map.json      exit 1 if a wire has two drivers
//
// A window of the device (a rectangle of the prjxray tile grid that covers whole frame columns of one clock-region row, and
// ends the row) is built on its own window chipdb around a static design built with `-o pr-window`; its frames are the only
// ones that differ, so they can be rewritten through ICAPE2 while the static design runs.  See xc7/pr_partial.py for merge
// and extract.  Two things here have no Python original beyond the prototypes they came from, for a small board that cannot
// hold the full tilegrid.json:
//
//   prep    (host, once per harness)
//     synthgui --tool pr-partial --tilegrid tilegrid.json --window x0,y0,x1,y1 prep harness.fasm OUTDIR
//                                [--db-root DB/FAMILY --part PART [--minidb DIR]]
//     OUTDIR/base.fasm      the harness lines outside the window whose tile lies in the window's frame row, at or after the
//                           window's first column
//     OUTDIR/tilegrid.json  the tiles of that row and the window's
//     OUTDIR/window.txt     the window's tiles
//     OUTDIR/row.txt        "half row first-FAR", what the fast extract needs
//     with --db-root and --part, also a trimmed prjxray database (default OUTDIR/minidb) that fasm2frames can read: mapping/*,
//     the part directory, the trimmed tilegrid at <fabric>/tilegrid.json, the tile_type_ and segbits_/ppips_/mask_ files
//     (.db and .block_ram.db) of the tile types in that grid and of the types they alias, and segbits_/ppips_/mask_int*.
//
//   extract --row (board, no tilegrid)
//     synthgui --tool pr-partial extract frames out.icap --row row.txt [--idcode ...] [--frames-out F]
//     cat base.fasm window.fasm > merged.fasm, fasm2frames against the trimmed database, then this: the same words as extract,
//     for block type 0 only.  There is no tilegrid to prove anything with, so no --ref and no tail-column check; prep and the
//     full extract are where those hold.  Block RAM contents of a window are NOT written on this path: a warning says so if
//     the frames carry any in this row.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "../common/pycompat.hpp"
#include "../common/toolio.hpp"

namespace pr_partial_tool {

namespace fs = std::filesystem;
using std::string;
using std::string_view;
using std::vector;
using pycompat::V;

[[noreturn]] static void die(const string& m) {
    toolio::err("pr_partial: %s\n", m.c_str());
    throw toolio::Exit{1};
}

static const int WORDS_PER_FRAME = 101, ZERO_FRAMES_PER_ROW = 2;
// configuration registers and commands, UG470 table 5-23 / 5-24
enum { REG_FAR = 1, REG_FDRI = 2, REG_CMD = 4, REG_IDCODE = 12 };
enum { CMD_WCFG = 1, CMD_RCRC = 7, CMD_DESYNC = 13 };

static unsigned far_block(uint32_t f) { return (f >> 23) & 7; }
static unsigned far_half(uint32_t f) { return (f >> 22) & 1; }
static unsigned far_row(uint32_t f) { return (f >> 17) & 31; }
static unsigned far_column(uint32_t f) { return (f >> 7) & 1023; }

// ---------------------------------------------------------------- the tile grid
struct TileBits { uint32_t base; int64_t frames; bool clb_io_clk; };
struct Tile { string type; int64_t x, y; vector<TileBits> bits; };

static Tile tile_of(const V& t) {
    Tile r;
    r.type = t.at("type").s();
    r.x = t.at("grid_x").as_int();
    r.y = t.at("grid_y").as_int();
    if (const V* bits = t.o().find("bits"))
        for (const auto& kv : bits->o().items()) {
            TileBits b;
            b.base = (uint32_t)pycompat::to_int(kv.second.at("baseaddr").s(), 0);
            b.frames = kv.second.at("frames").as_int();
            b.clb_io_clk = kv.first == "CLB_IO_CLK";
            r.bits.push_back(b);
        }
    return r;
}
using Grid = std::unordered_map<string, Tile>;

static Grid load_tilegrid(const string& path) {
    string text = pycompat::read_file(path);
    pycompat::Parser jp(text, path);
    Grid g;
    jp.members([&](const string& name, V v) { g[name] = tile_of(v); });
    return g;
}

struct Window { int64_t x0, y0, x1, y1; bool has(const Tile& t) const { return x0 <= t.x && t.x <= x1 && y0 <= t.y && t.y <= y1; } };
static Window parse_window(const string& text) {
    vector<int64_t> v;
    size_t i = 0;
    for (;;) {
        size_t j = text.find(',', i);
        v.push_back(pycompat::to_int(string_view(text).substr(i, j == string::npos ? string::npos : j - i), 10));
        if (j == string::npos) break;
        i = j + 1;
    }
    if (v.size() != 4) die("--window " + text + ": expected x0,y0,x1,y1");
    return {v[0], v[1], v[2], v[3]};
}

// every frame address of a window tile by block type (0: CLB_IO_CLK, 1: BLOCK_RAM contents), and the one row they share
struct WindowFrames { std::map<unsigned, std::set<uint32_t>> fars; unsigned half = 0, row = 0; };
static WindowFrames window_frames(const Grid& g, const Window& w) {
    WindowFrames r;
    std::set<std::pair<unsigned, unsigned>> rows;
    for (const auto& kv : g) {
        if (!w.has(kv.second)) continue;
        for (const TileBits& b : kv.second.bits) {
            for (int64_t i = 0; i < b.frames; i++) r.fars[far_block(b.base)].insert(b.base + (uint32_t)i);
            rows.insert({far_half(b.base), far_row(b.base)});
        }
    }
    if (rows.size() != 1) {
        string list = "[";
        for (auto it = rows.begin(); it != rows.end(); ++it)
            list += (it == rows.begin() ? "(" : ", (") + std::to_string(it->first) + ", " + std::to_string(it->second) + ")";
        die("window spans " + std::to_string(rows.size()) + " frame-address rows, it must be one clock-region row: " + list + "]");
    }
    r.half = rows.begin()->first;
    r.row = rows.begin()->second;
    return r;
}

// ---------------------------------------------------------------- frames
struct Frames {
    std::map<uint32_t, size_t> index;                           // FAR -> first word, ascending as sorted() gives it
    vector<uint32_t> words;
    const uint32_t* find(uint32_t far) const {
        auto it = index.find(far);
        return it == index.end() ? nullptr : &words[it->second];
    }
    const uint32_t* get(uint32_t far) const { return &words[index.at(far)]; }
    bool same(uint32_t far, const Frames& other) const {
        const uint32_t* o = other.find(far);
        return o && !memcmp(get(far), o, WORDS_PER_FRAME * sizeof(uint32_t));
    }
};

// one number of a frames file: "0x%08X" is what they all are, anything else goes the slow way
static uint32_t frame_word(string_view w, const string& path) {
    if (w.size() == 10 && w[0] == '0' && (w[1] == 'x' || w[1] == 'X')) {
        uint32_t v = 0;
        bool ok = true;
        for (size_t i = 2; i < 10 && ok; i++) {
            char c = w[i];
            uint32_t d = c >= '0' && c <= '9' ? (uint32_t)(c - '0') : c >= 'a' && c <= 'f' ? (uint32_t)(c - 'a' + 10) : c >= 'A' && c <= 'F' ? (uint32_t)(c - 'A' + 10) : 16;
            ok = d < 16;
            v = v << 4 | d;
        }
        if (ok) return v;
    }
    int64_t v = pycompat::to_int(w, 0);
    if (v < 0 || v > 0xFFFFFFFFll) die(path + ": " + string(w) + " is not a 32-bit word");
    return (uint32_t)v;
}

// keep(far) says which frames to hold (and parse): the fast path takes one row of a file it need not hold whole
template <class Keep, class Other> static Frames read_frames(const string& path, Keep&& keep, Other&& other) {
    string text = pycompat::read_file(path);
    Frames fr;
    pycompat::for_each_line(text, [&](string_view raw) {
        string_view line = pycompat::strip(raw);
        if (line.empty()) return;
        size_t sp = line.find(' ');
        if (sp == string_view::npos) die(path + ": bad frame line");
        string_view addr = line.substr(0, sp), data = line.substr(sp + 1);
        uint32_t far = frame_word(addr, path);
        if (!keep(far)) { other(far, data); return; }
        size_t at = fr.words.size();
        fr.words.resize(at + WORDS_PER_FRAME);
        int n = 0;
        size_t i = 0;
        for (;;) {
            size_t j = data.find(',', i);
            string_view w = data.substr(i, j == string_view::npos ? string_view::npos : j - i);
            if (n < WORDS_PER_FRAME) fr.words[at + (size_t)n] = frame_word(w, path);
            n++;
            if (j == string_view::npos) break;
            i = j + 1;
        }
        if (n != WORDS_PER_FRAME) die(path + ": frame " + string(addr) + " has " + std::to_string(n) + " words");
        auto ins = fr.index.emplace(far, at);
        if (!ins.second) {                                      // a repeated address: last one wins, as in the dict
            std::copy(fr.words.begin() + (std::ptrdiff_t)at, fr.words.end(), fr.words.begin() + (std::ptrdiff_t)ins.first->second);
            fr.words.resize(at);
        }
    });
    return fr;
}
static Frames read_frames(const string& path) {
    return read_frames(path, [](uint32_t) { return true; }, [](uint32_t, string_view) {});
}

// ---------------------------------------------------------------- merge
static string_view tile_of_line(string_view line) {
    size_t dot = line.find('.');
    return pycompat::strip(dot == string_view::npos ? line : line.substr(0, dot));
}

static int cmd_merge(const string& tilegrid, const string& window, const vector<string>& pos) {
    if (pos.size() != 4) die("usage: pr-partial --tilegrid T --window W merge harness.fasm window.fasm merged.fasm");
    Grid g = load_tilegrid(tilegrid);
    Window w = parse_window(window);
    std::unordered_set<string> inside;
    for (const auto& kv : g) if (w.has(kv.second)) inside.insert(kv.first);
    string out;
    size_t dropped = 0, added = 0, lines = 0;
    string text = pycompat::read_file(pos[1]);
    pycompat::for_each_line(text, [&](string_view raw) {
        string_view s = pycompat::strip(raw);
        if (s.empty() || s[0] == '#') return;
        if (inside.count(string(tile_of_line(s)))) { dropped++; return; }
        out.append(s); out += '\n'; lines++;
    });
    text = pycompat::read_file(pos[2]);
    pycompat::for_each_line(text, [&](string_view raw) {
        string_view s = pycompat::strip(raw);
        if (s.empty() || s[0] == '#') return;
        string tile(tile_of_line(s));
        if (!inside.count(tile)) {
            if (!g.count(tile)) die("window FASM names unknown tile " + tile);
            die("window FASM line is outside the window: " + string(s));
        }
        out.append(s); out += '\n'; lines++; added++;
    });
    if (out.empty()) out = "\n";                                // "\n".join([]) + "\n"
    pycompat::write_file(pos[3], out);
    toolio::out("merge: %zu harness lines in the window dropped, %zu window lines added, %zu lines written\n", dropped, added, lines);
    return 0;
}

// ---------------------------------------------------------------- check
// Two drivers on one wire of the merged design.  Across tiles only the nodes in the window map are known, which is every node
// that crosses the window's edge, the only ones a harness and a window can both drive; nodes wholly inside the window are
// checked by tile and wire alone, so two tiles driving one interior node are not seen here.
static int cmd_check(const vector<string>& pos, const string& map_path) {
    if (pos.size() != 2 || map_path.empty()) die("usage: pr-partial check merged.fasm --map window-map.json");
    V wmap = pycompat::load(map_path);
    const pycompat::Object& wires = wmap.at("wires").o();
    std::map<string, std::set<string>> drivers;
    size_t pips = 0;
    string text = pycompat::read_file(pos[1]);
    pycompat::for_each_line(text, [&](string_view raw) {
        string_view s = pycompat::strip(raw);
        size_t d1 = s.find('.');
        if (d1 == string_view::npos) return;
        size_t d2 = s.find('.', d1 + 1);
        if (d2 == string_view::npos || s.find('.', d2 + 1) != string_view::npos) return;
        const string wire(s.substr(0, d1)); const string key = wire + "/" + string(s.substr(d1 + 1, d2 - d1 - 1));
        const V* canon = wires.find(key);
        if (canon && canon->type() != V::Null) drivers[canon->s()].insert(string(s));
        else if (wire.compare(0, 4, "INT_") == 0) drivers[key].insert(string(s));
        else return;
        pips++;
    });
    size_t bad = 0;
    for (const auto& kv : drivers) {
        if (kv.second.size() < 2) continue;
        bad++;
        string list;
        for (const string& d : kv.second) { if (!list.empty()) list += ", "; list += d; }
        toolio::out("  %s: %s\n", kv.first.c_str(), list.c_str());
    }
    toolio::out("check: %zu pips onto %zu wires, %zu with two or more drivers\n", pips, drivers.size(), bad);
    if (bad) die("a node has two drivers: this design has a short, no image");
    return 0;
}

// ---------------------------------------------------------------- the ICAPE2 word stream
struct Block { uint32_t far; vector<uint32_t> data; };

static vector<uint32_t> icap_words(const vector<Block>& blocks, uint32_t idcode) {
    auto type1 = [](uint32_t op, uint32_t reg, uint32_t count) { return (1u << 29) | (op << 27) | (reg << 13) | count; };
    auto type2 = [](uint32_t op, uint32_t count) { return (2u << 29) | (op << 27) | count; };
    const uint32_t W = 2, NOP = type1(0, 0, 0);
    vector<uint32_t> w(8, 0xFFFFFFFFu);
    auto add = [&](std::initializer_list<uint32_t> l) { w.insert(w.end(), l.begin(), l.end()); };
    add({0x000000BBu, 0x11220044u, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xAA995566u});
    add({NOP});
    add({type1(W, REG_CMD, 1), CMD_RCRC, NOP, NOP});
    add({type1(W, REG_IDCODE, 1), idcode, NOP});
    for (const Block& b : blocks) {
        add({type1(W, REG_FAR, 1), b.far});
        add({type1(W, REG_CMD, 1), CMD_WCFG, NOP});
        add({type1(W, REG_FDRI, 0), type2(W, (uint32_t)b.data.size())});
        w.insert(w.end(), b.data.begin(), b.data.end());
        add({NOP});
    }
    add({type1(W, REG_CMD, 1), CMD_RCRC, NOP, NOP});
    add({type1(W, REG_CMD, 1), CMD_DESYNC, NOP, NOP, NOP, NOP});
    return w;
}
static void write_words(const string& path, const vector<uint32_t>& words) {
    string out;
    out.resize(words.size() * 4);
    size_t i = 0;
    for (uint32_t x : words) {
        out[i++] = (char)(x >> 24); out[i++] = (char)(x >> 16); out[i++] = (char)(x >> 8); out[i++] = (char)x;
    }
    pycompat::write_file(path, out);
}
static uint32_t parse_idcode(const string& text) {
    int64_t v = pycompat::to_int(text, 0);
    if (v < 0 || v > 0xFFFFFFFFll) die("--idcode " + text + " is not a 32-bit word");
    return (uint32_t)v;
}
static void write_frames_text(const string& path, const vector<uint32_t>& fars, const Frames& fr) {
    string out;
    out.reserve(fars.size() * (11 + WORDS_PER_FRAME * 11));
    char b[16];
    for (uint32_t far : fars) {
        snprintf(b, sizeof b, "0x%08x ", far);
        out += b;
        const uint32_t* d = fr.get(far);
        for (int i = 0; i < WORDS_PER_FRAME; i++) {
            snprintf(b, sizeof b, i ? ",0x%08x" : "0x%08x", d[i]);
            out += b;
        }
        out += '\n';
    }
    pycompat::write_file(path, out);
}
static void write_u32_hex(char (&b)[16], uint32_t v) { snprintf(b, sizeof b, "0x%08x", v); }

// ---------------------------------------------------------------- extract, with the tile grid
static int cmd_extract(const string& tilegrid, const string& window, const string& frames_path, const string& out_path,
                       const string& ref_path, const string& idcode_text, const string& frames_out) {
    Grid g = load_tilegrid(tilegrid);
    Window win = parse_window(window);
    WindowFrames wf = window_frames(g, win);
    Frames frames = read_frames(frames_path);
    bool has_ref = !ref_path.empty();
    Frames ref;
    if (has_ref) ref = read_frames(ref_path);
    std::set<uint32_t> all_wfars;
    for (const auto& kv : wf.fars) all_wfars.insert(kv.second.begin(), kv.second.end());
    char hex[16];
    {
        size_t missing = 0;
        uint32_t first = 0;
        for (uint32_t f : all_wfars) if (!frames.find(f)) { if (!missing) first = f; missing++; }
        if (missing) {
            write_u32_hex(hex, first);
            die(std::to_string(missing) + " window frames are not in " + frames_path + " (first " + hex + ")");
        }
    }
    if (has_ref) {
        size_t diff = 0;
        uint32_t first = 0;
        for (const auto& kv : frames.index)
            if (!all_wfars.count(kv.first) && !frames.same(kv.first, ref)) { if (!diff) first = kv.first; diff++; }
        if (diff) {
            write_u32_hex(hex, first);
            die(std::to_string(diff) + " frames differ OUTSIDE the window (first " + hex + "): the static design changed, the image would not be partial");
        }
    }
    vector<Block> blocks;
    vector<string> report;
    for (const auto& kv : wf.fars) {
        unsigned blk = kv.first;
        const std::set<uint32_t>& wfars = kv.second;
        size_t changed = 0;
        if (has_ref) for (uint32_t f : wfars) if (!frames.same(f, ref)) changed++;
        // block type 0 is always written; a block RAM contents block only when it changed
        if (blk != 0 && has_ref && changed == 0) {
            report.push_back("block type " + std::to_string(blk) + ": " + std::to_string(wfars.size()) + " window frames unchanged, not written");
            continue;
        }
        uint32_t first = *wfars.begin();
        vector<uint32_t> rowf;
        for (const auto& fi : frames.index)
            if (fi.first >= first && far_block(fi.first) == blk && far_half(fi.first) == wf.half && far_row(fi.first) == wf.row) rowf.push_back(fi.first);
        std::set<unsigned> wcols, tail;
        for (uint32_t f : wfars) wcols.insert(far_column(f));
        for (uint32_t f : rowf) if (!wcols.count(far_column(f))) tail.insert(far_column(f));
        // FAR column -> the types of the tiles with CLB_IO_CLK frames in it, of this row
        std::map<unsigned, std::set<string>> cols;
        for (const auto& t : g)
            for (const TileBits& b : t.second.bits)
                if (b.clb_io_clk && far_block(b.base) == blk && far_half(b.base) == wf.half && far_row(b.base) == wf.row)
                    cols[far_column(b.base)].insert(t.second.type);
        for (unsigned c : tail) {
            vector<string> clb;
            auto ci = cols.find(c);
            if (ci != cols.end()) for (const string& ty : ci->second) if (ty.compare(0, 3, "CLB") == 0) clb.push_back(ty);
            if (!clb.empty())
                die("tail column " + std::to_string(c) + " (after the window, before the row end) holds CLB tiles " + pycompat::repr_list(clb) + ": a window must end its row's CLB columns");
            if (blk != 0) die("tail column " + std::to_string(c) + " of block type " + std::to_string(blk) + ": the window must end its row's block RAM columns");
        }
        if (has_ref)
            for (uint32_t f : rowf)
                if (!wfars.count(f) && !frames.same(f, ref)) die("internal: tail frames differ");
        Block block;
        block.far = first;
        block.data.reserve((rowf.size() + (size_t)ZERO_FRAMES_PER_ROW) * WORDS_PER_FRAME);
        for (uint32_t f : rowf) { const uint32_t* d = frames.get(f); block.data.insert(block.data.end(), d, d + WORDS_PER_FRAME); }
        block.data.insert(block.data.end(), (size_t)(WORDS_PER_FRAME * ZERO_FRAMES_PER_ROW), 0u);
        blocks.push_back(std::move(block));
        write_u32_hex(hex, first);
        string line = "block type " + std::to_string(blk) + ": window " + std::to_string(wfars.size()) + " frames in columns " +
                      std::to_string(*wcols.begin()) + ".." + std::to_string(*wcols.rbegin()) + ", image from " + hex + ": " +
                      std::to_string(rowf.size()) + " frames + " + std::to_string(ZERO_FRAMES_PER_ROW) + " zero frames, tail columns " +
                      pycompat::int_list(tail);
        if (has_ref) line += ", " + std::to_string(changed) + " frames changed";
        report.push_back(line);
        if (!frames_out.empty()) write_frames_text(blk == 0 ? frames_out : frames_out + ".type" + std::to_string(blk), rowf, frames);
    }
    vector<uint32_t> words = icap_words(blocks, parse_idcode(idcode_text));
    write_words(out_path, words);
    toolio::out("extract: window %s, frame row half %u row %u\n", window.c_str(), wf.half, wf.row);
    for (const string& r : report) toolio::out("  %s\n", r.c_str());
    toolio::out("  %zu words (%zu bytes) -> %s%s\n", words.size(), 4 * words.size(), out_path.c_str(),
                has_ref && !ref.index.empty() ? "; no frame outside the window differs from the reference" : "");
    return 0;
}

// ---------------------------------------------------------------- extract --row: block type 0 from prep's row.txt, no tile grid
static int cmd_extract_row(const string& row_path, const string& frames_path, const string& out_path, const string& idcode_text, const string& frames_out) {
    string row_text = pycompat::read_file(row_path);
    vector<string_view> f;
    {
        string_view s = pycompat::strip(row_text);
        while (!s.empty()) {
            size_t i = 0;
            while (i < s.size() && !pycompat::py_space(s[i])) i++;
            f.push_back(s.substr(0, i));
            s = pycompat::strip(s.substr(i));
        }
    }
    if (f.size() != 3) die(row_path + ": expected \"half row first-FAR\"");
    const int64_t half = pycompat::to_int(f[0], 0), row = pycompat::to_int(f[1], 0), first64 = pycompat::to_int(f[2], 0);
    if (first64 < 0 || first64 > 0xFFFFFFFFll) die(row_path + ": bad first FAR");
    const uint32_t first = (uint32_t)first64;
    if (far_block(first) != 0 || far_half(first) != half || far_row(first) != row) die(row_path + ": the first FAR is not in block type 0 of that row");
    size_t bram_nonzero = 0;
    auto in_row = [&](uint32_t far) { return far_block(far) == 0 && far_half(far) == half && far_row(far) == row && far >= first; };
    Frames frames = read_frames(frames_path, in_row, [&](uint32_t far, string_view data) {
        if (far_block(far) != 1 || far_half(far) != half || far_row(far) != row) return;
        for (size_t i = data.find('x'); i != string_view::npos; i = data.find('x', i + 1))
            for (size_t k = i + 1; k < data.size() && data[k] != ','; k++)
                if (data[k] != '0') { bram_nonzero++; return; }
    });
    if (frames.index.empty()) die(frames_path + ": no frame of block type 0 in that row at or after the first FAR");
    if (bram_nonzero)
        toolio::err("pr_partial: warning: %zu block RAM content frames of this row are not zero; extract --row writes block type 0 only\n", bram_nonzero);
    vector<uint32_t> fars;
    Block block;
    block.far = first;
    block.data.reserve((frames.index.size() + (size_t)ZERO_FRAMES_PER_ROW) * WORDS_PER_FRAME);
    for (const auto& kv : frames.index) {
        fars.push_back(kv.first);
        const uint32_t* d = &frames.words[kv.second];
        block.data.insert(block.data.end(), d, d + WORDS_PER_FRAME);
    }
    block.data.insert(block.data.end(), (size_t)(WORDS_PER_FRAME * ZERO_FRAMES_PER_ROW), 0u);
    vector<Block> blocks;
    blocks.push_back(std::move(block));
    vector<uint32_t> words = icap_words(blocks, parse_idcode(idcode_text));
    write_words(out_path, words);
    if (!frames_out.empty()) write_frames_text(frames_out, fars, frames);
    toolio::out("extract: frame row half %lld row %lld from 0x%08x, block type 0: %zu frames + %d zero frames\n", (long long)half, (long long)row, first, fars.size(), ZERO_FRAMES_PER_ROW);
    toolio::out("  %zu words (%zu bytes) -> %s\n", words.size(), 4 * words.size(), out_path.c_str());
    return 0;
}

// ---------------------------------------------------------------- prep
// prjxray-db's mapping/*.yaml: "key:" at column 0, "  field: value" below it; the one field of one key
static string yaml_field(const string& path, const string& key, const string& field) {
    string text = pycompat::read_file(path), cur;
    string found;
    auto unq = [](string_view s) {
        s = pycompat::strip(s);
        if (s.size() >= 2 && (s[0] == '"' || s[0] == '\'') && s.back() == s[0]) s = s.substr(1, s.size() - 2);
        return string(s);
    };
    pycompat::for_each_line(text, [&](string_view line) {
        string_view st = pycompat::strip(line);
        if (st.empty() || st[0] == '#') return;
        size_t c = line.find(':');
        if (c == string_view::npos) return;
        if (!pycompat::py_space(line[0])) cur = unq(line.substr(0, c));
        else if (cur == key && unq(line.substr(0, c)) == field) found = unq(line.substr(c + 1));
    });
    if (found.empty()) die(path + ": no " + field + " for " + key);
    return found;
}

static string lower(string s) { for (auto& c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a'); return s; }
static string upper(string s) { for (auto& c : s) if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A'); return s; }

static size_t copy_into(const fs::path& from, const fs::path& to) {
    fs::create_directories(to.parent_path());
    fs::copy_file(from, to, fs::copy_options::overwrite_existing);
    return 1;
}

static size_t make_minidb(const fs::path& db, const string& part, const fs::path& out, const string& tilegrid_text, const std::set<string>& types) {
    const string parts_yaml = (db / "mapping" / "parts.yaml").string();
    const string device = yaml_field(parts_yaml, part, "device");
    const string fabric = yaml_field((db / "mapping" / "devices.yaml").string(), device, "fabric");
    if (fs::exists(out) && fs::equivalent(db, out)) die("--minidb " + out.string() + " is the database itself");
    size_t n = 0;
    for (const auto& e : fs::directory_iterator(db / "mapping")) if (e.is_regular_file()) n += copy_into(e.path(), out / "mapping" / e.path().filename());
    for (const auto& e : fs::directory_iterator(db / part)) if (e.is_regular_file()) n += copy_into(e.path(), out / part / e.path().filename());
    fs::create_directories(out / fabric);
    pycompat::write_file((out / fabric / "tilegrid.json").string(), tilegrid_text);
    n++;
    // the top of the database: exact names per tile type, in a directory of a few hundred files
    std::set<string> wanted;
    for (const string& t : types) {
        wanted.insert("tile_type_" + upper(t) + ".json");
        for (const char* pre : {"segbits_", "ppips_", "mask_"}) {
            wanted.insert(pre + lower(t) + ".db");
            wanted.insert(pre + lower(t) + ".block_ram.db");
        }
    }
    for (const auto& e : fs::directory_iterator(db)) {
        if (!e.is_regular_file()) continue;
        string name = e.path().filename().string();
        bool intfile = name.compare(0, 11, "segbits_int") == 0 || name.compare(0, 9, "ppips_int") == 0 || name.compare(0, 8, "mask_int") == 0;
        if (intfile || wanted.count(name)) n += copy_into(e.path(), out / name);
    }
    return n;
}

static int cmd_prep(const string& tilegrid, const string& window, const vector<string>& pos, const string& db_root, const string& part, const string& minidb) {
    if (pos.size() != 3) die("usage: pr-partial --tilegrid T --window W prep harness.fasm OUTDIR [--db-root DB/FAMILY --part PART [--minidb DIR]]");
    if (db_root.empty() != part.empty()) die("prep: --db-root and --part go together");
    if (!minidb.empty() && db_root.empty()) die("prep: --minidb needs --db-root and --part");
    V grid = pycompat::load(tilegrid);
    Window win = parse_window(window);
    Grid g;
    for (const auto& kv : grid.o().items()) g[kv.first] = tile_of(kv.second);
    WindowFrames wf = window_frames(g, win);
    if (!wf.fars.count(0)) die("window has no frames of block type 0");
    const uint32_t first = *wf.fars[0].begin();
    const unsigned first_col = far_column(first);
    std::unordered_set<string> inside, keep;
    vector<string> sorted_inside;
    for (const auto& kv : g) {
        if (win.has(kv.second)) {
            inside.insert(kv.first);
            keep.insert(kv.first);
            sorted_inside.push_back(kv.first);
            continue;
        }
        for (const TileBits& b : kv.second.bits)
            if (far_half(b.base) == wf.half && far_row(b.base) == wf.row && far_block(b.base) == 0 && far_column(b.base) >= first_col) { keep.insert(kv.first); break; }
    }
    std::sort(sorted_inside.begin(), sorted_inside.end());
    const fs::path out(pos[2]);
    fs::create_directories(out);
    string base;
    size_t lines = 0;
    string text = pycompat::read_file(pos[1]);
    pycompat::for_each_line(text, [&](string_view raw) {
        string_view s = pycompat::strip(raw);
        if (s.empty() || s[0] == '#') return;
        string t(tile_of_line(s));
        if (keep.count(t) && !inside.count(t)) { base.append(s); base += '\n'; lines++; }
    });
    pycompat::write_file((out / "base.fasm").string(), base);
    // the kept tiles, in the grid's own order (a Python set's order, in the prototype, changes from run to run)
    V trimmed = V::object();
    std::set<string> types;
    for (const auto& kv : grid.o().items()) {
        if (!keep.count(kv.first)) continue;
        types.insert(kv.second.at("type").s());
        if (const V* bits = kv.second.o().find("bits"))
            for (const auto& b : bits->o().items())
                if (const V* al = b.second.o().find("alias")) types.insert(al->at("type").s());
        trimmed.o().set(kv.first, kv.second);
    }
    string grid_text;
    pycompat::dump(trimmed, grid_text, -1);
    pycompat::write_file((out / "tilegrid.json").string(), grid_text);
    string list;
    for (const string& t : sorted_inside) { list += t; list += '\n'; }
    if (list.empty()) list = "\n";
    pycompat::write_file((out / "window.txt").string(), list);
    pycompat::write_file((out / "row.txt").string(), std::to_string(wf.half) + " " + std::to_string(wf.row) + " " + std::to_string(first) + "\n");
    toolio::out("kept %zu tiles of %zu (%zu in the window), base.fasm %zu lines, row half %u row %u first 0x%08x\n",
                keep.size(), g.size(), inside.size(), lines, wf.half, wf.row, first);
    if (!db_root.empty()) {
        const fs::path mini = minidb.empty() ? out / "minidb" : fs::path(minidb);
        size_t n = make_minidb(db_root, part, mini, grid_text, types);
        toolio::out("minidb: %zu files -> %s\n", n, mini.string().c_str());
    }
    return 0;
}

static const char* const USAGE =
    "usage: pr-partial --tilegrid TILEGRID --window x0,y0,x1,y1 merge harness.fasm window.fasm out.fasm\n"
    "       pr-partial check merged.fasm --map window-map.json\n"
    "       pr-partial --tilegrid TILEGRID --window x0,y0,x1,y1 extract frames out.icap [--ref FRAMES] [--idcode ID] [--frames-out F]\n"
    "       pr-partial extract frames out.icap --row row.txt [--idcode ID] [--frames-out F]\n"
    "       pr-partial --tilegrid TILEGRID --window x0,y0,x1,y1 prep harness.fasm OUTDIR [--db-root DB/FAMILY --part PART [--minidb DIR]]\n";

int tool_main(int argc, char** argv) {
    try {
        pycompat::Args a = pycompat::parse_args(argc, argv, {"--tilegrid", "--window", "--ref", "--idcode", "--frames-out", "--row", "--db-root", "--part", "--minidb", "--map"});
        if (a.help) { toolio::out("%s", USAGE); return 0; }
        const string cmd = a.pos.empty() ? string() : a.pos[0];
        if (cmd == "check") return cmd_check(a.pos, a.get("--map"));
        const string idcode = a.get("--idcode", "0x03687093");
        if (cmd == "extract" && a.has("--row")) {
            if (a.pos.size() != 3) { toolio::err("%s", USAGE); return 2; }
            if (a.has("--ref")) die("--ref needs the tile grid: use the full extract");
            return cmd_extract_row(a.get("--row"), a.pos[1], a.pos[2], idcode, a.get("--frames-out"));
        }
        if ((cmd != "merge" && cmd != "extract" && cmd != "prep") || !a.has("--tilegrid") || !a.has("--window")) { toolio::err("%s", USAGE); return 2; }
        if (cmd == "merge") return cmd_merge(a.get("--tilegrid"), a.get("--window"), a.pos);
        if (cmd == "prep") return cmd_prep(a.get("--tilegrid"), a.get("--window"), a.pos, a.get("--db-root"), a.get("--part"), a.get("--minidb"));
        if (a.pos.size() != 3) { toolio::err("%s", USAGE); return 2; }
        return cmd_extract(a.get("--tilegrid"), a.get("--window"), a.pos[1], a.pos[2], a.get("--ref"), idcode, a.get("--frames-out"));
    } catch (std::exception& e) {
        toolio::err("pr_partial: %s\n", e.what());
        return 1;
    }
}

}  // namespace pr_partial_tool

int pr_partial_main(int argc, char** argv) {
    try {
        return pr_partial_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    }
}
