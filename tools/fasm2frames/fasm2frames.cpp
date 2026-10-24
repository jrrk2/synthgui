// Derived from Project X-Ray's utils/fasm2frames.py and prjxray/{fasm_assembler,tile_segbits,tile_segbits_alias,grid,db}.py:
//   Copyright (C) 2017-2020  The Project X-Ray Authors.
//   Use of this source code is governed by a ISC-style license that can be found in the LICENSE file or at
//   https://opensource.org/licenses/ISC
//   SPDX-License-Identifier: ISC
// This is a C++ port (the openXC7/prjxray version, with its IO-bank and glue rules); the logic, the messages and the
// output follow the Python.
//
// fasm2frames -- Project X-Ray's utils/fasm2frames.py (as shipped in openXC7/prjxray, with its IO-bank and glue rules)
// in C++, so a bitstream needs no Python.
//
//   synthgui --tool fasm2frames --part xc7a50tcsg324-1 --db-root prjxray-db/artix7 [--allow-missing-features] in.fasm out.frames
//
// out.frames is the .frm text xc7frames2bit reads ("0x%08X " + 101 comma separated "0x%08X" words per frame, ascending).
// Same inputs, same output: tools/fasm2frames/compare.sh runs this against the Python on any FASM and diffs the files.
//
// Covered: what xc7/convert.py asks of fasm2frames (a part, no ROI, dense frames, no PUDC_B pull-up request).
// Not covered: --sparse, --roi, --emit_pudc_b_pullup, --debug.  The FASM reader accepts the subset xc7/fasm_fast.py does
// (tile.feature, [i] or [hi:lo], = value, # comments; no annotations) and anything else is an error rather than a guess.
#include <algorithm>
#include <cctype>
#include <cstdint>
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
#include <utility>
#include <vector>
#include <dirent.h>
#include "../common/minijson.hpp"
#include "../common/toolio.hpp"
#include <sys/stat.h>

namespace fasm2frames_tool {

using std::string;
using std::vector;

[[noreturn]] static void die(const string& m) {
    toolio::err("fasm2frames: %s\n", m.c_str());
    throw toolio::Exit{1};
}
struct LookupError : std::runtime_error { using std::runtime_error::runtime_error; };   // FasmLookupError
static const int WORD_BITS = 32, FRAME_WORDS = 101;

static bool exists(const string& p) { struct stat s; return stat(p.c_str(), &s) == 0; }
static string slurp(const string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) die("cannot open " + p);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
static vector<string> split(const string& s, char c) {
    vector<string> out;
    size_t i = 0;
    for (;;) {
        size_t j = s.find(c, i);
        if (j == string::npos) { out.push_back(s.substr(i)); return out; }
        out.push_back(s.substr(i, j - i));
        i = j + 1;
    }
}
static string join(const vector<string>& v, size_t from, char c) {
    string r;
    for (size_t i = from; i < v.size(); i++) { if (i > from) r += c; r += v[i]; }
    return r;
}
static string lower(string s) { for (auto& c : s) c = tolower((unsigned char)c); return s; }
static string upper(string s) { for (auto& c : s) c = toupper((unsigned char)c); return s; }
static string strip(const string& s) {
    size_t a = 0, b = s.size();
    while (a < b && isspace((unsigned char)s[a])) a++;
    while (b > a && isspace((unsigned char)s[b - 1])) b--;
    return s.substr(a, b - a);
}
static bool starts(const string& s, const char* p) { return s.compare(0, strlen(p), p) == 0; }
static bool contains(const string& s, const char* p) { return s.find(p) != string::npos; }

using minijson::JV;
using minijson::JP;
using minijson::json_file;

// minimal YAML for prjxray-db's mapping/*.yaml: "key:" at column 0, "  field: value" below it
static std::map<string, std::map<string, string>> yaml_map(const string& path) {
    std::map<string, std::map<string, string>> m;
    std::ifstream f(path);
    if (!f) die("Mapping file " + path + " does not exist");
    string line, cur;
    auto unq = [](string s) {
        s = strip(s);
        if (s.size() >= 2 && (s[0] == '"' || s[0] == '\'') && s.back() == s[0]) s = s.substr(1, s.size() - 2);
        return s;
    };
    while (std::getline(f, line)) {
        if (strip(line).empty() || strip(line)[0] == '#') continue;
        size_t c = line.find(':');
        if (c == string::npos) continue;
        if (!isspace((unsigned char)line[0])) { cur = unq(line.substr(0, c)); m[cur]; }
        else m[cur][unq(line.substr(0, c))] = unq(line.substr(c + 1));
    }
    return m;
}

// ---------------------------------------------------------------- the database
struct Bit { uint32_t col; uint32_t bit; bool isset; };    // word_column, word_bit
enum BlockType { CLB_IO_CLK = 0, BLOCK_RAM = 1 };
struct Alias { string tile_type; int start_offset = 0; std::map<string, string> sites; };
struct Bits { uint32_t base = 0; int frames = 0, offset = 0, words = 0; bool has_alias = false; Alias alias; };
struct Tile {
    string name, type;
    int x = 0, y = 0;
    vector<std::pair<int, Bits>> bits;                     // block type -> bits, in tilegrid order
    vector<string> sites;                                  // site names
    vector<std::pair<string, string>> pin_functions;
    const Bits* find(int bt) const { for (auto& b : bits) if (b.first == bt) return &b.second; return nullptr; }
};

struct TileSegbits {
    vector<std::pair<int, std::unordered_map<string, vector<Bit>>>> segbits;       // CLB_IO_CLK first, then BLOCK_RAM
    std::unordered_set<string> ppips;
    std::unordered_map<string, std::map<int, std::pair<int, string>>> feature_addresses;

    static Bit parsebit(const string& v) {
        Bit b{0, 0, true};
        size_t i = 0;
        if (v.empty()) die("empty bit in a segbits file");
        if (v[0] == '!') { b.isset = false; i = 1; }
        size_t u = v.find('_', i);
        if (u == string::npos) die("bad segbit " + v);
        b.col = (uint32_t)strtoul(v.substr(i, u - i).c_str(), nullptr, 10);
        b.bit = (uint32_t)strtoul(v.substr(u + 1).c_str(), nullptr, 10);
        return b;
    }
    static std::pair<vector<string>, std::unordered_map<string, vector<Bit>>> read_segbits(const string& path) {
        std::pair<vector<string>, std::unordered_map<string, vector<Bit>>> r;
        std::ifstream f(path);
        if (!f) die("cannot open " + path);
        string line;
        while (std::getline(f, line)) {
            line = strip(line);
            if (line.empty()) continue;
            vector<string> parts = split(line, ' ');
            if (parts.size() < 2) die("bad segbits line: " + line);
            vector<Bit> bits;
            for (size_t i = 1; i < parts.size(); i++) bits.push_back(parsebit(parts[i]));
            if (!r.second.count(parts[0])) r.first.push_back(parts[0]);
            r.second[parts[0]] = std::move(bits);
        }
        return r;
    }
    TileSegbits(const string& segbits_path, const string& bram_path, const string& ppips_path) {
        if (!ppips_path.empty()) {
            std::ifstream f(ppips_path);
            string line;
            while (std::getline(f, line)) {
                line = strip(line);
                if (line.empty()) continue;
                ppips.insert(split(line, ' ')[0]);
            }
        }
        vector<vector<string>> order;
        if (!segbits_path.empty()) { auto r = read_segbits(segbits_path); order.push_back(r.first); segbits.emplace_back(CLB_IO_CLK, std::move(r.second)); }
        else order.emplace_back();
        if (!bram_path.empty()) {
            auto r = read_segbits(bram_path);
            order.resize(segbits.size() + 1);
            order[segbits.size()] = r.first;
            segbits.emplace_back(BLOCK_RAM, std::move(r.second));
        }
        for (size_t k = 0; k < segbits.size(); k++) {
            int bt = segbits[k].first;
            for (const string& feature : order[k]) {
                size_t s = feature.rfind('['), e = feature.rfind(']');
                if (s != string::npos) {
                    if (e == string::npos) die("bad feature " + feature);
                    feature_addresses[feature.substr(0, s)][atoi(feature.substr(s + 1, e - s - 1).c_str())] = {bt, feature};
                }
            }
        }
    }
    const vector<Bit>* find(int bt, const string& feature) const {
        for (auto& b : segbits) if (b.first == bt) { auto it = b.second.find(feature); return it == b.second.end() ? nullptr : &it->second; }
        return nullptr;
    }
    // features' bits mapped to frame coordinates; throws LookupError where the Python raised KeyError
    template <class Map, class Out>
    void feature_to_bits(const Map& bits_map, const string& feature, int address, Out&& out) const {
        if (ppips.count(feature)) return;
        auto emit = [&](int bt, const vector<Bit>& bl) {
            const Bits* b = bits_map(bt);
            if (!b) throw LookupError("no bits for block type");
            for (const Bit& bit : bl) out(bt, Bit{b->base + bit.col, (uint32_t)(b->offset * WORD_BITS) + bit.bit, bit.isset});
        };
        for (auto& blk : segbits) {
            if (address == 0) {
                auto it = blk.second.find(feature);
                if (it != blk.second.end()) { emit(blk.first, it->second); return; }
            }
        }
        auto fa = feature_addresses.find(feature);
        if (fa == feature_addresses.end()) throw LookupError("feature");
        auto ad = fa->second.find(address);
        if (ad == fa->second.end()) throw LookupError("address");
        emit(ad->second.first, *find(ad->second.first, ad->second.second));
    }
};

struct Database {
    string root, part, fabric;
    std::set<string> tile_types;                                          // upper case, those with a tile_type_*.json
    std::unordered_map<string, std::unique_ptr<TileSegbits>> segbits;
    vector<Tile> tiles;
    std::unordered_map<string, size_t> tile_index;
    std::set<string> required_features;
    std::unordered_map<string, string> fabric_json_dirs;

    Database(const string& db_root, const string& part_) : root(db_root), part(part_) {
        auto parts = yaml_map(root + "/mapping/parts.yaml");
        auto pi = parts.find(part);
        if (pi == parts.end()) die("Part " + part + " not found in " + root + "/mapping/parts.yaml");
        string device = pi->second["device"];
        auto devs = yaml_map(root + "/mapping/devices.yaml");
        auto di = devs.find(device);
        if (di == devs.end()) die("Device " + device + " not found in devices.yaml");
        fabric = di->second["fabric"];
        if (DIR* d = opendir(root.c_str())) {
            while (dirent* e = readdir(d)) {
                string n = e->d_name;
                if (starts(n, "tile_type_") && n.size() > 15 && n.substr(n.size() - 5) == ".json")
                    tile_types.insert(upper(n.substr(10, n.size() - 15)));
            }
            closedir(d);
        }
        string rf = root + "/" + part + "/required_features.fasm";
        if (exists(rf)) {
            std::ifstream f(rf);
            string line;
            while (std::getline(f, line)) { line = strip(line); if (!line.empty()) required_features.insert(line); }
        }
        read_tilegrid();
    }
    void read_tilegrid() {
        string tg = root + "/" + fabric + "/tilegrid.json";
        if (!exists(tg)) tg = root + "/tilegrid.json";
        string text = slurp(tg);
        JP jp{text.data(), text.data() + text.size(), tg};
        jp.ws();
        if (jp.p >= jp.e || *jp.p != '{') die(tg + ": not a JSON object");
        jp.p++;
        for (;;) {
            jp.ws();
            if (jp.p < jp.e && *jp.p == '}') break;
            string name = jp.str(); jp.ws();
            if (*jp.p != ':') die(tg + ": expected ':'");
            jp.p++;
            JV v = jp.value();
            Tile t;
            t.name = name;
            t.type = v.get("type")->s;
            t.x = (int)v.get("grid_x")->n;
            t.y = (int)v.get("grid_y")->n;
            if (const JV* b = v.get("bits")) {
                for (auto& kv : b->o) {
                    int bt;
                    if (kv.first == "CLB_IO_CLK") bt = CLB_IO_CLK;
                    else if (kv.first == "BLOCK_RAM") bt = BLOCK_RAM;
                    else die(tg + ": unknown block type " + kv.first);
                    Bits bits;
                    bits.base = (uint32_t)strtoul(kv.second.get("baseaddr")->s.c_str(), nullptr, 0);
                    bits.frames = (int)kv.second.get("frames")->n;
                    bits.offset = (int)kv.second.get("offset")->n;
                    bits.words = (int)kv.second.get("words")->n;
                    if (const JV* al = kv.second.get("alias")) {
                        bits.has_alias = true;
                        bits.alias.tile_type = al->get("type")->s;
                        bits.alias.start_offset = (int)al->get("start_offset")->n;
                        for (auto& s : al->get("sites")->o) bits.alias.sites[s.first] = s.second.s;
                    }
                    t.bits.emplace_back(bt, std::move(bits));
                }
            }
            if (const JV* s = v.get("sites")) for (auto& kv : s->o) t.sites.push_back(kv.first);
            if (const JV* pf = v.get("pin_functions")) for (auto& kv : pf->o) t.pin_functions.emplace_back(kv.first, kv.second.s);
            tile_index[name] = tiles.size();
            tiles.push_back(std::move(t));
            jp.ws();
            if (jp.p < jp.e && *jp.p == ',') jp.p++;
        }
    }
    const Tile* tile(const string& name) const {
        auto it = tile_index.find(name);
        return it == tile_index.end() ? nullptr : &tiles[it->second];
    }
    const TileSegbits& get_tile_segbits(const string& tile_type) {
        auto it = segbits.find(tile_type);
        if (it != segbits.end()) return *it->second;
        string up = upper(tile_type);
        if (!tile_types.count(up)) throw std::out_of_range("tile type " + tile_type);
        string lo = lower(up);
        auto path = [&](const char* pre, const char* suf) {
            string p = root + "/" + pre + lo + suf;
            return exists(p) ? p : string();
        };
        auto ts = std::make_unique<TileSegbits>(path("segbits_", ".db"), path("segbits_", ".block_ram.db"), path("ppips_", ".db"));
        auto& ref = *ts;
        segbits[tile_type] = std::move(ts);
        return ref;
    }
    bool has_own_segbits(const string& tile_type) const {
        string p = root + "/segbits_" + lower(tile_type) + ".db";
        return tile_types.count(upper(tile_type)) && exists(p);
    }
};

// ---------------------------------------------------------------- the assembler
struct FasmInconsistent : std::runtime_error { using std::runtime_error::runtime_error; };

struct Assembler {
    Database& db;
    // (frame, word, bit) -> 1 set / 0 cleared, and the line that said so
    struct Cell { uint32_t val : 1; uint32_t line : 31; };
    std::unordered_map<uint64_t, Cell> frames;
    vector<string> extra_lines;                       // text of lines that did not come from the file
    string file;
    vector<string> file_lines_cache;
    bool lines_loaded = false;
    // the features seen (the Python's set_features): name -> any set with value != 0
    std::unordered_set<string> feature_names;
    vector<string> feature_order;
    std::unordered_map<string, std::unique_ptr<struct AliasView>> alias_views;

    explicit Assembler(Database& d) : db(d) {}
    string line_text(uint32_t id) {
        if (id & 0x40000000) return extra_lines[id & 0x3fffffff];
        if (!lines_loaded) {
            std::ifstream f(file);
            string l;
            while (std::getline(f, l)) file_lines_cache.push_back(l);
            lines_loaded = true;
        }
        return id >= 1 && id <= file_lines_cache.size() ? strip(file_lines_cache[id - 1]) : string("?");
    }
    static uint64_t key(uint32_t frame, uint32_t word, uint32_t bit) { return ((uint64_t)frame << 16) | (word << 5) | bit; }
    string key_str(uint64_t k) {
        char b[96];
        snprintf(b, sizeof b, "(%u, %u, %u)", (unsigned)(k >> 16), (unsigned)((k >> 5) & 0x7ff), (unsigned)(k & 31));
        return b;
    }
    void set_bit(const Bit& bit, uint32_t line) {
        uint32_t word = bit.bit / WORD_BITS, idx = bit.bit % WORD_BITS;
        if (word >= (uint32_t)FRAME_WORDS) {
            toolio::err("frame_%s: invalid word address %u in line: %s\n", bit.isset ? "set" : "clear", word, line_text(line).c_str());
            return;
        }
        uint64_t k = key(bit.col, word, idx);
        auto it = frames.find(k);
        if (it != frames.end()) {
            if (it->second.val != (bit.isset ? 1u : 0u))
                throw FasmInconsistent("FASM line \"" + line_text(line) + "\" wanted to " + (bit.isset ? "set" : "clear") + " bit " +
                                       key_str(k) + " but was " + (bit.isset ? "cleared" : "set") + " by FASM line \"" +
                                       line_text(it->second.line) + "\"");
            return;
        }
        Cell c; c.val = bit.isset ? 1u : 0u; c.line = line;
        frames[k] = c;
    }
    void enable_feature(const string& tilename, const string& feature, int address, uint32_t line);
    void add_feature(const string& full_feature, int start, int end, const vector<uint8_t>& valbits, uint32_t line,
                     vector<string>& missing);
    void add_text_line(const string& text, vector<string>& missing);
};

// the tile's segbits, through its alias when it has one
struct AliasView {
    string tile_type, alias_type;
    std::map<int, Bits> alias_bits_map;
    vector<std::pair<int, std::map<string, string>>> sites;          // per block type: site -> alias site
    const TileSegbits* ts = nullptr;
    std::unordered_set<string> ppips;
};

void Assembler::enable_feature(const string& tilename, const string& feature, int address, uint32_t line) {
    const Tile* t = db.tile(tilename);
    if (!t) die("unknown tile " + tilename + " in line: " + line_text(line));
    string db_k = t->type + "." + feature;
    bool any_alias = false;
    for (auto& b : t->bits) if (b.second.has_alias) any_alias = true;
    auto sink = [&](int, const Bit& bit) { set_bit(bit, line); };
    try {
        if (any_alias && !db.has_own_segbits(t->type)) {
            auto it = alias_views.find(tilename);
            if (it == alias_views.end()) {
                auto av = std::make_unique<AliasView>();
                av->tile_type = t->type;
                for (auto& b : t->bits) {
                    if (av->alias_type.empty()) av->alias_type = b.second.alias.tile_type;
                    Bits ab = b.second;
                    ab.offset = b.second.offset - b.second.alias.start_offset;
                    ab.has_alias = false;
                    av->alias_bits_map[b.first] = ab;
                    av->sites.emplace_back(b.first, b.second.alias.sites);
                }
                av->ts = &db.get_tile_segbits(av->alias_type);
                string p = db.root + "/ppips_" + lower(t->type) + ".db";
                if (exists(p)) {
                    std::ifstream f(p);
                    string l;
                    while (std::getline(f, l)) { l = strip(l); if (!l.empty()) av->ppips.insert(split(l, ' ')[0]); }
                }
                it = alias_views.emplace(tilename, std::move(av)).first;
            }
            AliasView& av = *it->second;
            if (av.ppips.count(db_k)) return;
            vector<string> parts = split(db_k, '.');
            parts[0] = av.alias_type;
            for (auto& s : av.sites)
                if (parts.size() > 1) { auto m = s.second.find(parts[1]); if (m != s.second.end()) parts[1] = m->second; }
            auto bm = [&](int bt) -> const Bits* { auto f = av.alias_bits_map.find(bt); return f == av.alias_bits_map.end() ? nullptr : &f->second; };
            av.ts->feature_to_bits(bm, join(parts, 0, '.'), address, sink);
        } else {
            const TileSegbits& ts = db.get_tile_segbits(t->type);
            auto bm = [&](int bt) -> const Bits* { return t->find(bt); };
            ts.feature_to_bits(bm, db_k, address, sink);
        }
    } catch (LookupError&) {
        throw LookupError("Segment DB " + t->type + ", key " + db_k + " not found from line '" + line_text(line) + "'");
    } catch (std::out_of_range&) {
        throw LookupError("Segment DB " + t->type + ", key " + db_k + " not found from line '" + line_text(line) + "'");
    }
}

void Assembler::add_feature(const string& full, int start, int end, const vector<uint8_t>& vb, uint32_t line,
                            vector<string>& missing) {
    bool nonzero = false;
    for (uint8_t b : vb) if (b) { nonzero = true; break; }
    if (nonzero && feature_names.insert(full).second) feature_order.push_back(full);
    if (!nonzero) return;
    vector<string> parts = split(full, '.');
    string tile = parts[0], feature = join(parts, 1, '.');
    auto one = [&](int address) {
        try { enable_feature(tile, feature, address, line); }
        catch (LookupError& e) { missing.push_back(e.what()); }
    };
    if (start < 0) { one(0); return; }                              // no brackets
    if (end < 0) { one(start); return; }                            // [i]
    for (int a = start; a <= end; a++) {
        size_t i = a - start;
        if (i < vb.size() && vb[i]) one(a);
    }
}

// ---------------------------------------------------------------- FASM lines
struct FasmLine { bool has = false; string feature; int start = -1, end = -1; vector<uint8_t> bits; };

static FasmLine parse_fasm_line(const string& text_in, int lineno) {
    FasmLine r;
    string text = text_in;
    if (!text.empty() && text.back() == '\n') text.pop_back();
    if (text.find('{') != string::npos || text.find('}') != string::npos)
        die("line " + std::to_string(lineno) + ": FASM annotations are not supported by this reader");
    size_t i = 0, n = text.size();
    auto bad = [&]() { die("line " + std::to_string(lineno) + ": cannot read FASM line '" + text + "'"); };
    while (i < n && (text[i] == ' ' || text[i] == '\t')) i++;
    if (i == n || text[i] == '#') return r;
    if (!(isalpha((unsigned char)text[i]) || text[i] == '_')) bad();
    size_t f0 = i;
    while (i < n && (isalnum((unsigned char)text[i]) || text[i] == '_' || text[i] == '.')) i++;
    r.feature = text.substr(f0, i - f0);
    r.has = true;
    int hi = -1, lo = -1;
    bool bracket = false;
    if (i < n && text[i] == '[') {
        size_t j = i + 1, d0 = j;
        while (j < n && isdigit((unsigned char)text[j])) j++;
        if (j == d0) bad();
        hi = atoi(text.substr(d0, j - d0).c_str());
        if (j < n && text[j] == ':') {
            size_t k = j + 1, d1 = k;
            while (k < n && isdigit((unsigned char)text[k])) k++;
            if (k == d1) bad();
            lo = atoi(text.substr(d1, k - d1).c_str());
            j = k;
        }
        if (j >= n || text[j] != ']') bad();
        i = j + 1;
        bracket = true;
    }
    if (!bracket) { r.start = r.end = -1; }
    else if (lo < 0) { r.start = hi; r.end = -1; }
    else { r.start = lo; r.end = hi; }
    size_t save = i;
    while (i < n && (text[i] == ' ' || text[i] == '\t')) i++;
    string raw;
    bool has_value = false;
    if (i < n && text[i] == '=') {
        i++;
        while (i < n && (text[i] == ' ' || text[i] == '\t')) i++;
        if (i >= n || text[i] == '#' || isspace((unsigned char)text[i])) bad();
        size_t v0 = i;
        while (i < n && text[i] != '#') i++;
        raw = strip(text.substr(v0, i - v0));
        has_value = true;
    } else i = save;
    while (i < n && (text[i] == ' ' || text[i] == '\t')) i++;
    if (i < n && text[i] != '#') bad();
    // value
    vector<uint8_t> bits;                                           // little endian
    if (!has_value) bits = {1};
    else {
        int radix = 10;
        string digits;
        size_t q = raw.find('\'');
        if (q != string::npos && q > 0 && q + 1 < raw.size()) {
            for (size_t k = 0; k < q; k++) if (!isdigit((unsigned char)raw[k])) die("line " + std::to_string(lineno) + ": cannot read FASM value '" + raw + "'");
            char b = tolower(raw[q + 1]);
            radix = b == 'b' ? 2 : b == 'o' ? 8 : b == 'd' ? 10 : b == 'h' ? 16 : 0;
            if (!radix) die("line " + std::to_string(lineno) + ": cannot read FASM value '" + raw + "'");
            digits = raw.substr(q + 2);
        } else digits = raw;
        string clean;
        for (char c : digits) if (c != '_') clean += c;
        if (clean.empty() || digits.empty()) die("line " + std::to_string(lineno) + ": cannot read FASM value '" + raw + "'");
        // arbitrary precision: repeated multiply-add on a little endian bit vector
        vector<uint32_t> limbs{0};
        for (char c : clean) {
            int d = isdigit((unsigned char)c) ? c - '0' : isalpha((unsigned char)c) ? tolower(c) - 'a' + 10 : 99;
            if (d >= radix) die("line " + std::to_string(lineno) + ": cannot read FASM value '" + raw + "'");
            uint64_t carry = d;
            for (auto& l : limbs) { uint64_t x = (uint64_t)l * radix + carry; l = (uint32_t)x; carry = x >> 32; }
            if (carry) limbs.push_back((uint32_t)carry);
        }
        for (size_t li = 0; li < limbs.size(); li++) for (int b = 0; b < 32; b++) bits.push_back((limbs[li] >> b) & 1);
        while (bits.size() > 1 && !bits.back()) bits.pop_back();
        int width = r.end >= 0 ? r.end - r.start + 1 : 1;
        // value >= 1 << width is an error
        size_t bl = 0;
        for (size_t k = 0; k < bits.size(); k++) if (bits[k]) bl = k + 1;
        if ((int)bl > width) die("line " + std::to_string(lineno) + ": value " + raw + " does not fit in " + std::to_string(width) + " bit(s)");
    }
    r.bits = std::move(bits);
    return r;
}

void Assembler::add_text_line(const string& text, vector<string>& missing) {
    FasmLine l = parse_fasm_line(text, 0);
    if (!l.has) return;
    extra_lines.push_back(strip(text));
    add_feature(l.feature, l.start, l.end, l.bits, 0x40000000u | (uint32_t)(extra_lines.size() - 1), missing);
}

// ---------------------------------------------------------------- helpers from fasm2frames.py
// "(.*)_X(\d+)Y(\d+)" matched against a whole tile name
static bool tile_xy(const string& t, string& prefix, string& x, string& y) {
    size_t e = t.size(), i = e;
    while (i > 0 && isdigit((unsigned char)t[i - 1])) i--;
    if (i == e || i == 0 || t[i - 1] != 'Y') return false;
    y = t.substr(i, e - i);
    size_t yp = i - 1, j = yp;
    while (j > 0 && isdigit((unsigned char)t[j - 1])) j--;
    if (j == yp || j < 2 || t[j - 1] != 'X' || t[j - 2] != '_') return false;
    x = t.substr(j, yp - j);
    prefix = t.substr(0, j - 2);
    return true;
}

static vector<vector<string>> read_csv(const string& path) {
    vector<vector<string>> rows;
    std::ifstream f(path);
    if (!f) die("cannot open " + path);
    string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        vector<string> cells;
        string cur;
        bool q = false;
        for (char c : line) {
            if (c == '"') q = !q;
            else if (c == ',' && !q) { cells.push_back(cur); cur.clear(); }
            else cur += c;
        }
        cells.push_back(cur);
        rows.push_back(cells);
    }
    return rows;
}

struct Run {
    Database db;
    Assembler as;
    vector<string> t2b_order;
    std::unordered_map<string, string> tile_to_bank;
    std::map<string, std::set<string>> bank_to_tile;
    bool allow_missing = false;

    Run(const string& root, const string& part) : db(root, part), as(db) {}

    void set_tile_bank(const string& tile, const string& bank) {
        if (!tile_to_bank.count(tile)) t2b_order.push_back(tile);
        tile_to_bank[tile] = bank;
    }
    void add_line(const string& text, vector<string>& missing) { as.add_text_line(text, missing); }
    static string join_missing(const vector<string>& m) { string r; for (size_t i = 0; i < m.size(); i++) { if (i) r += '\n'; r += m[i]; } return r; }

    void fabric_aliases(const JV& part_data) {
        const JV* fab = part_data.get("fabric");
        if (!fab || fab->t != JV::Str) return;
        string path = db.root + "/" + fab->s + "/tilegrid.json";
        if (!exists(path)) return;
        string text = slurp(path);
        JP jp{text.data(), text.data() + text.size(), path};
        vector<string> fabric_tiles;
        jp.ws(); jp.p++;
        for (;;) {
            jp.ws();
            if (jp.p < jp.e && *jp.p == '}') break;
            fabric_tiles.push_back(jp.str()); jp.ws(); jp.p++; jp.value(); jp.ws();
            if (jp.p < jp.e && *jp.p == ',') jp.p++;
        }
        std::unordered_set<string> fabric_set(fabric_tiles.begin(), fabric_tiles.end());
        std::map<std::pair<string, string>, string> by_prefix_y;
        for (const string& t : t2b_order) {
            string pre, x, y;
            if (!tile_xy(t, pre, x, y)) continue;
            by_prefix_y.emplace(std::make_pair(pre, y), t);
        }
        int added = 0, replaced = 0;
        for (const string& ft : fabric_tiles) {
            if (tile_to_bank.count(ft)) continue;
            string pre, x, y;
            if (!tile_xy(ft, pre, x, y)) continue;
            auto it = by_prefix_y.find({pre, y});
            if (it == by_prefix_y.end()) continue;
            string bank = tile_to_bank[it->second];
            set_tile_bank(ft, bank);
            added++;
            if (!fabric_set.count(it->second) && bank_to_tile[bank].count(it->second)) {
                bank_to_tile[bank].erase(it->second);
                bank_to_tile[bank].insert(ft);
                replaced++;
            }
        }
        if (added)
            toolio::out("INFO: added %d fabric/package tile-name alias(es) to tile_to_bank (%d also replaced in bank_to_tile)\n", added, replaced);
    }

    // (tile, site) of the PUDC_B pin
    bool find_pudc_b(string& tile, string& site) {
        bool found = false;
        for (const Tile& t : db.tiles)
            for (auto& pf : t.pin_functions)
                if (contains(pf.second, "PUDC_B")) {
                    if (found) die("AssertionError: two PUDC_B pins, " + tile + " and " + t.name);
                    int y = (pf.first.back() - '0') % 2;
                    tile = t.name; site = "IOB_Y" + std::to_string(y);
                    found = true;
                }
        return found;
    }
    vector<string> iob_sites(const string& tile) {
        const Tile* t = db.tile(tile);
        if (!t) die("KeyError: tile " + tile);
        vector<string> r;
        for (const string& s : t->sites) r.push_back("IOB_Y" + std::to_string((s.back() - '0') % 2));
        return r;
    }

    int run(const string& fasm, const string& out_path) {
        const string& part = db.part;
        as.file = fasm;
        // IO banks
        vector<std::pair<string, string>> iobanks;
        JV part_data = json_file(db.root + "/" + part + "/part.json");
        {
            auto rows = read_csv(db.root + "/" + part + "/package_pins.csv");
            if (const JV* ib = part_data.get("iobanks"))
                for (auto& kv : ib->o)
                    for (const char* prefix : {"HCLK_IOI3_", "HCLK_IOI_"}) {
                        string tile = string(prefix) + kv.second.s;
                        if (!db.tile(tile)) continue;
                        bank_to_tile[kv.first].insert(tile);
                        set_tile_bank(tile, kv.first);
                        break;
                    }
            if (rows.empty()) die("empty package_pins.csv");
            int ib = -1, it = -1;
            for (size_t i = 0; i < rows[0].size(); i++) { if (rows[0][i] == "bank") ib = (int)i; if (rows[0][i] == "tile") it = (int)i; }
            if (ib < 0 || it < 0) die("package_pins.csv has no bank/tile columns");
            for (size_t r = 1; r < rows.size(); r++) {
                if (rows[r].size() <= (size_t)std::max(ib, it)) continue;
                bank_to_tile[rows[r][ib]].insert(rows[r][it]);
                set_tile_bank(rows[r][it], rows[r][ib]);
            }
            fabric_aliases(part_data);
        }
        string pudc_tile, pudc_site;
        bool have_pudc = find_pudc_b(pudc_tile, pudc_site);

        // the FASM, then the part's required features
        vector<string> missing;
        {
            std::ifstream f(fasm);
            if (!f) die("cannot open " + fasm);
            string text;
            int lineno = 0;
            while (std::getline(f, text)) {
                lineno++;
                FasmLine l = parse_fasm_line(text, lineno);
                if (!l.has) continue;
                as.add_feature(l.feature, l.start, l.end, l.bits, (uint32_t)lineno, missing);
            }
        }
        for (const string& rf : db.required_features) add_line(rf, missing);
        if (!missing.empty()) {
            if (allow_missing) {
                toolio::err("WARNING: %zu missing-feature lines suppressed by XRAY_ALLOW_MISSING_FEATURES=1:\n", missing.size());
                for (auto& m : missing) toolio::err("  %s\n", m.c_str());
            } else {
                toolio::err("fasm2frames: FasmLookupError:\n%s\n", join_missing(missing).c_str());
                return 1;
            }
        }

        // STEPDOWN: when one IOB of a bank has it, every unused IOB of the bank gets it
        {
            std::map<string, std::set<string>> stepdown_tags;
            std::set<string> stepdown_banks;
            std::set<std::pair<string, string>> used;
            vector<string> names = as.feature_order;               // the features set so far
            for (const string& feature : names) {
                vector<string> parts = split(feature, '.');
                if (parts.size() >= 3) {
                    string tile = parts[0], site = parts[1], tag = join(parts, 2, '.');
                    if (contains(tile, "IOB33")) used.insert({tile, site});
                    if (contains(tag, "STEPDOWN")) {
                        auto b = tile_to_bank.find(tile);
                        if (b == tile_to_bank.end()) { toolio::out("WARNING: skipping STEPDOWN for unmapped tile: %s\n", tile.c_str()); continue; }
                        stepdown_banks.insert(b->second);
                        stepdown_tags[b->second].insert(tag);
                    }
                }
            }
            vector<string> miss;
            for (const string& bank : stepdown_banks)
                for (const string& tile : bank_to_tile[bank]) {
                    if (contains(tile, "IOB33"))
                        for (const string& site : iob_sites(tile)) {
                            if (used.count({tile, site})) continue;
                            for (const string& tag : stepdown_tags[bank]) add_line(tile + "." + site + "." + tag, miss);
                        }
                    if (contains(tile, "HCLK_IOI3") || starts(tile, "HCLK_IOI_")) add_line(tile + ".STEPDOWN", miss);
                }
            if (!miss.empty()) { toolio::err("fasm2frames: FasmLookupError:\n%s\n", join_missing(miss).c_str()); return 1; }
        }

        // HP-bank glue
        {
            struct Kind { bool in = false, out = false, diff_in = false; };
            std::map<std::pair<string, string>, Kind> kinds;
            vector<string> names = as.feature_order;
            for (const string& feature : names) {
                vector<string> parts = split(feature, '.');
                if (parts.size() < 3) continue;
                const string &tile = parts[0], &site = parts[1];
                string tag = join(parts, 2, '.');
                if (!(starts(tile, "LIOB18") || starts(tile, "RIOB18"))) continue;
                if (site != "IOB_Y0" && site != "IOB_Y1") continue;
                if (contains(tag, "IN_DIFF")) kinds[{tile, site}].diff_in = true;
                else if (contains(tag, "IN_ONLY") || (tag.size() >= 3 && tag.compare(tag.size() - 3, 3, ".IN") == 0) || contains(tag, "IBUFDISABLE"))
                    kinds[{tile, site}].in = true;
                if (contains(tag, ".DRIVE.")) kinds[{tile, site}].out = true;
            }
            vector<string> glue_missing;
            bool any_y1_obuf = false;
            for (auto& kv : kinds) {
                const string& tile = kv.first.first;
                const string& site = kv.first.second;
                if (have_pudc && tile == pudc_tile) continue;
                if (kv.second.in) add_line(tile + "." + site + ".IBUF_HP_BANK_GLUE", glue_missing);
                if (kv.second.out) add_line(tile + "." + site + ".OBUF_HP_BANK_GLUE", glue_missing);
                if (kv.second.diff_in) add_line(tile + ".IOB_Y0.IBUFDS_BANK_GLUE", glue_missing);
                if (kv.second.out && site == "IOB_Y1" && starts(tile, "LIOB18_X81")) any_y1_obuf = true;
            }
            if (any_y1_obuf) {
                add_line("INT_L_X32Y49.IOB_COL_OBUF_CASCADE_Y1", glue_missing);
                add_line("INT_L_X32Y49.IOB_COL_BANK_ACTIVE", glue_missing);
            }
            // GFAN0 T-tie root glue
            string gfan_tile;
            for (const string& feat : as.feature_order) {
                if (!starts(feat, "INT_L_X62")) continue;
                if (contains(feat, "GFAN0.GND_WIRE")) {
                    string tile = split(feat, '.')[0];
                    // re.match(r'(INT_L_X(\d+))Y(\d+)', tile)
                    if (starts(tile, "INT_L_X")) {
                        size_t i = 7, j = i;
                        while (j < tile.size() && isdigit((unsigned char)tile[j])) j++;
                        if (j > i && j < tile.size() && tile[j] == 'Y') {
                            size_t k = j + 1, l = k;
                            while (l < tile.size() && isdigit((unsigned char)tile[l])) l++;
                            if (l > k) gfan_tile = "INT_L_X" + tile.substr(i, j - i) + "Y" + std::to_string(atoi(tile.substr(k, l - k).c_str()) + 10);
                        }
                    }
                    break;
                }
            }
            if (!gfan_tile.empty()) add_line(gfan_tile + ".GFAN_TIE_ROOT_GLUE", glue_missing);
            // HCLK_L BUFRCLK "active" markers
            std::map<string, std::set<int>> hclkl;
            for (const string& feat : as.feature_order) {
                vector<string> parts = split(feat, '.');
                if (parts.size() < 3 || !starts(parts[0], "HCLK_L")) continue;
                string tag = join(parts, 2, '.');
                size_t p = tag.rfind("HCLK_CK_BUFRCLK");
                if (p == string::npos) continue;
                string ch = tag.substr(p + strlen("HCLK_CK_BUFRCLK"));
                if (!ch.empty() && std::all_of(ch.begin(), ch.end(), [](char c) { return isdigit((unsigned char)c); }))
                    hclkl[parts[0]].insert(atoi(ch.c_str()));
            }
            for (auto& kv : hclkl)
                for (int ch : kv.second)
                    if (ch == 3) add_line(kv.first + ".HCLK_LEAF_BUFRCLK3_ACTIVE", glue_missing);
        }
        return write_frames(out_path);
    }

    int write_frames(const string& out_path) {
        // frames_init: every frame of every tile, zero; then the bits
        vector<uint32_t> addrs;
        for (const Tile& t : db.tiles)
            for (auto& b : t.bits)
                for (int c = 0; c < b.second.frames; c++) addrs.push_back(b.second.base + c);
        for (auto& kv : as.frames) addrs.push_back((uint32_t)(kv.first >> 16));
        std::sort(addrs.begin(), addrs.end());
        addrs.erase(std::unique(addrs.begin(), addrs.end()), addrs.end());
        std::unordered_map<uint32_t, size_t> idx;
        idx.reserve(addrs.size() * 2);
        for (size_t i = 0; i < addrs.size(); i++) idx[addrs[i]] = i;
        vector<uint32_t> words(addrs.size() * FRAME_WORDS, 0);
        for (auto& kv : as.frames) {
            if (!kv.second.val) continue;
            uint32_t frame = (uint32_t)(kv.first >> 16), word = (kv.first >> 5) & 0x7ff, bit = kv.first & 31;
            words[idx[frame] * FRAME_WORDS + word] |= 1u << bit;
        }
        FILE* f = out_path.empty() ? nullptr : fopen(out_path.c_str(), "w");
        if (!out_path.empty() && !f) die("cannot write " + out_path);
        string line;
        char buf[16];
        for (size_t i = 0; i < addrs.size(); i++) {
            line.clear();
            snprintf(buf, sizeof buf, "0x%08X ", addrs[i]);
            line += buf;
            for (int w = 0; w < FRAME_WORDS; w++) {
                if (w) line += ',';
                snprintf(buf, sizeof buf, "0x%08X", words[i * FRAME_WORDS + w]);
                line += buf;
            }
            line += '\n';
            if (f) fwrite(line.data(), 1, line.size(), f);
            else toolio::write(false, line.data(), line.size());
        }
        if (f) fclose(f);
        return 0;
    }
};

int tool_main(int argc, char** argv) {
    string part, root, in, out;
    bool allow = getenv("XRAY_ALLOW_MISSING_FEATURES") && !strcmp(getenv("XRAY_ALLOW_MISSING_FEATURES"), "1");
    vector<string> pos;
    for (int i = 1; i < argc; i++) {
        string a = argv[i];
        if (a == "--part" && i + 1 < argc) part = argv[++i];
        else if (a == "--db-root" && i + 1 < argc) root = argv[++i];
        else if (a == "--allow-missing-features") allow = true;
        else if (a == "--sparse" || a == "--roi" || a == "--emit_pudc_b_pullup" || a == "--debug") die("option " + a + " is not implemented");
        else if (starts(a, "--")) die("unknown option " + a);
        else pos.push_back(a);
    }
    if (part.empty() || root.empty() || pos.empty() || pos.size() > 2)
        die("usage: synthgui --tool fasm2frames --part PART --db-root DB/FAMILY [--allow-missing-features] in.fasm [out.frames]");
    try {
        Run r(root, part);
        r.allow_missing = allow;
        return r.run(pos[0], pos.size() > 1 ? pos[1] : string());
    } catch (FasmInconsistent& e) {
        toolio::err("fasm2frames: FasmInconsistentBits: %s\n", e.what());
        return 1;
    } catch (std::exception& e) {
        toolio::err("fasm2frames: %s\n", e.what());
        return 1;
    }
}

}  // namespace fasm2frames_tool

int fasm2frames_main(int argc, char** argv) {
    try {
        return fasm2frames_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    }
}
