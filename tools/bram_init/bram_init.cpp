// bram-init -- replace block RAM contents in a routed FASM (see bram_init.hpp).
//
//   synthgui --tool bram-init --fasm routed.fasm [--placement placement.json] [--out patched.fasm]
//       --list                        every block RAM: tile, block, width, depth, cell, INIT lines
//       --dump KEY                    the contents of one (KEY = TILE or TILE/Y0, or a cell name with --placement)
//       --set KEY=image               new contents (repeatable); .hex/.mem is $readmemh, anything else raw words
//       --cell REGEX --hexdir DIR     lane<NN>.hex for every cell whose name matches, NN from the regex's group 1
//       --split image --line-size N --cell REGEX
//                                     byte lane NN of every N-byte line of a flat binary to the matching cells
//       --check                       say which block RAMs differ from the images, write nothing (exit 1 if any)
//       --meminit M.json              the memories the synthesis made (verilator --map-only-meminit), with --placement
//       --roms                        list them: name, width x depth, the file they were initialised from, cells placed
//       --rom NAME[=image]            a whole new image for memory NAME (default: the file it was synthesized from);
//                                     NAME all: every memory from its own file. Repeatable. Needs --placement.
//
// With --out the patched file is written; without, --set and friends only report. compare.sh checks the output
// against the Python that came first (vortex hw/syn/xilinx/vc707/update_bram_init.py) byte for byte.
#include "bram_init.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <regex>
#include <sstream>
#include <stdexcept>

#include "../common/minijson.hpp"
#include "../common/toolio.hpp"

namespace bram_init {

using std::string;
using std::vector;

[[noreturn]] static void die(const string& m) { throw std::runtime_error(m); }
static bool starts(const string& s, const char* p, size_t at = 0) { return s.compare(at, strlen(p), p) == 0; }

int width_from_code(int code, bool ramb36) {
    if (!ramb36) return code;
    switch (code) {                    // nextpnr writes half the RAMB36E1 port width on each RAMB18 half
        case 36: return 72;
        case 18: return 36;
        case 9: return 18;
        case 4: return 9;
        case 2: return 4;
        default: return 1;             // 1 or 2: the marker cannot tell them apart
    }
}

// "TILE.RAMB18_Yh.INIT_xx[255:0] = 256'b..." -> h, is parity, index; false for any other line
static bool init_line(const string& line, size_t after_tile, int& half, bool& parity, int& index) {
    if (!starts(line, "RAMB18_Y", after_tile)) return false;
    const size_t p = after_tile + 8;
    if (p + 1 >= line.size() || (line[p] != '0' && line[p] != '1') || line[p + 1] != '.') return false;
    half = line[p] - '0';
    size_t q = p + 2;
    if (!starts(line, "INIT", q)) return false;
    q += 4;
    parity = line[q] == 'P';
    if (parity) q++;
    if (line[q] != '_' || q + 3 >= line.size() || line[q + 3] != '[') return false;
    char* end = nullptr;
    index = (int)strtol(line.c_str() + q + 1, &end, 16);
    return end == line.c_str() + q + 3;
}

static void set_bits(std::array<bool, 256>& v, const string& line) {
    const size_t b = line.find("'b");
    if (b == string::npos) die("no 'b in: " + line);
    size_t k = 255;
    for (size_t i = b + 2; i < line.size() && k < 256; i++) {           // printed MSB first
        if (line[i] == '0' || line[i] == '1') v[k--] = line[i] == '1';
        else if (line[i] != '_') break;
    }
}

bool Tile::is36() const {
    if (mode) return mode == 36;
    if (ramb36) return true;
    const Half &a = half[0], &b = half[1];
    return a.in_use && b.in_use && a.read_width_a == b.read_width_a && a.read_width_b == b.read_width_b &&
           a.write_width_a == b.write_width_a && a.write_width_b == b.write_width_b;
}

void Fasm::load(const string& p) {
    path = p;
    std::ifstream f(p, std::ios::binary);
    if (!f) die("cannot open " + p);
    lines.clear();
    tiles.clear();
    brams.clear();
    order.clear();
    string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(line);
        if (!starts(line, "BRAM_")) continue;
        const size_t dot = line.find('.');
        if (dot == string::npos) continue;
        const string tname = line.substr(0, dot);
        auto it = tiles.find(tname);
        if (it == tiles.end()) {
            it = tiles.emplace(tname, Tile()).first;
            it->second.name = tname;
            order.push_back(tname);
        }
        Tile& t = it->second;
        int h, idx;
        bool parity;
        if (init_line(line, dot + 1, h, parity, idx)) {
            Half& H = t.half[h];
            if (parity) { if (idx < 8) { H.has_initp[idx] = true; set_bits(H.initp[idx], line); } }
            else if (idx < 64) { H.has_init[idx] = true; set_bits(H.init[idx], line); }
            continue;
        }
        if (starts(line, "RAMB36.", dot + 1)) { t.ramb36 = true; continue; }
        if (starts(line, "RAMB18_Y", dot + 1) && line.size() > dot + 10 && line[dot + 10] == '.') {
            Half& H = t.half[line[dot + 9] - '0'];
            H.last_line = (long)lines.size() - 1;
            const string feat = line.substr(dot + 11);
            if (feat == "IN_USE") H.in_use = true;
            auto code = [&](const char* name, int& into) {
                if (!starts(feat, name)) return;
                const char* s = feat.c_str() + strlen(name);
                if (*s == '_' && isdigit((unsigned char)s[1])) into = atoi(s + 1);
            };
            code("READ_WIDTH_A", H.read_width_a);
            code("READ_WIDTH_B", H.read_width_b);
            code("WRITE_WIDTH_A", H.write_width_a);
            code("WRITE_WIDTH_B", H.write_width_b);
            if (feat == "SDP_READ_WIDTH_36") H.read_width_a = 36;
            if (feat == "SDP_WRITE_WIDTH_36") H.write_width_b = 36;
        }
    }
    rebuild();
}

void Fasm::rebuild() {
    brams.clear();
    for (const string& tname : order) {
        Tile& t = tiles[tname];
        auto code_of = [](const Half& H) {
            for (int c : {H.read_width_a, H.read_width_b, H.write_width_a, H.write_width_b}) if (c) return c;
            return 1;
        };
        if (t.is36()) {
            if (!t.half[0].in_use && !t.half[1].in_use) continue;
            Bram b;
            b.tile = tname;
            b.port_width = width_from_code(code_of(t.half[0].in_use ? t.half[0] : t.half[1]), true);
            b.cell = t.cell36;
            brams.push_back(b);
        } else {
            for (int h = 0; h < 2; h++) {
                if (!t.half[h].in_use) continue;
                Bram b;
                b.tile = tname;
                b.half = h;
                b.port_width = width_from_code(code_of(t.half[h]), false);
                b.cell = t.cell18[h];
                brams.push_back(b);
            }
        }
    }
}

void Fasm::set_mode(const string& tile, int mode) {
    auto it = tiles.find(tile);
    if (it == tiles.end()) die("no block RAM tile " + tile);
    it->second.mode = mode;
    rebuild();
}

void Fasm::name_cells(const string& placement) {
    minijson::JV doc = minijson::json_file(placement);
    for (auto& t : tiles) { t.second.cell36.clear(); t.second.cell18[0].clear(); t.second.cell18[1].clear(); }
    for (auto& kv : doc.o) {
        const minijson::JV* bel = kv.second.get("bel");
        const minijson::JV* tile = kv.second.get("tile");
        const minijson::JV* site = kv.second.get("site");
        if (!bel || !tile || bel->t != minijson::JV::Str || tile->t != minijson::JV::Str) continue;
        auto it = tiles.find(tile->s);
        if (it == tiles.end()) continue;
        Tile& t = it->second;
        if (bel->s == "RAMB36E1") {
            t.mode = 36;
            t.cell36 = kv.first;
        } else if (bel->s == "RAMB18E1") {
            if (!site || site->t != minijson::JV::Str) continue;
            const size_t y = site->s.rfind('Y');
            if (y == string::npos) continue;
            t.mode = 18;
            t.cell18[atoi(site->s.c_str() + y + 1) % 2] = kv.first;
        }
    }
    rebuild();
}

const Bram* Fasm::find(const string& key) const {
    for (const Bram& b : brams) if (b.key() == key) return &b;
    for (const Bram& b : brams) if (!b.cell.empty() && b.cell == key) return &b;
    return nullptr;
}

// the block RAM's INIT image as one bit array (32768 or 16384 data bits) and its parity bits
struct Bits {
    vector<bool> data, parity;
};

static Bits gather(const Tile& t, const Bram& b) {
    Bits r;
    if (b.half < 0) {
        r.data.assign(32768, false);
        r.parity.assign(4096, false);
        for (int L = 0; L < 128; L++)
            for (int bb = 0; bb < 256; bb++)
                r.data[L * 256 + bb] = t.half[bb & 1].init[L / 2][(L % 2) * 128 + bb / 2];
        for (int L = 0; L < 16; L++)
            for (int bb = 0; bb < 256; bb++)
                r.parity[L * 256 + bb] = t.half[bb & 1].initp[L / 2][(L % 2) * 128 + bb / 2];
    } else {
        const Half& H = t.half[b.half];
        r.data.assign(16384, false);
        r.parity.assign(2048, false);
        for (int L = 0; L < 64; L++) for (int bb = 0; bb < 256; bb++) r.data[L * 256 + bb] = H.init[L][bb];
        for (int L = 0; L < 8; L++) for (int bb = 0; bb < 256; bb++) r.parity[L * 256 + bb] = H.initp[L][bb];
    }
    return r;
}

static Image to_image(const Bits& bits, const Bram& b) {
    Image img;
    img.data_bits = b.data_bits();
    img.parity_bits = b.parity_bits();
    const int depth = b.depth();
    img.data.assign(depth, 0);
    for (int k = 0; k < depth; k++)
        for (int i = 0; i < img.data_bits; i++)
            if (bits.data[(size_t)k * img.data_bits + i]) img.data[k] |= (uint64_t)1 << i;
    if (img.parity_bits) {
        img.parity.assign(depth, 0);
        for (int k = 0; k < depth; k++)
            for (int j = 0; j < img.parity_bits; j++)
                if (bits.parity[(size_t)k * img.parity_bits + j]) img.parity[k] |= (uint64_t)1 << j;
    }
    return img;
}

Image Fasm::read(const Bram& b) const { return to_image(gather(tiles.at(b.tile), b), b); }

bool Fasm::same(const Bram& b, const Image& img) const {
    const Image now = read(b);
    if (now.data_bits != img.data_bits) return false;
    for (size_t k = 0; k < now.data.size(); k++)
        if (now.data[k] != (k < img.data.size() ? img.data[k] : 0)) return false;
    for (size_t k = 0; k < now.parity.size(); k++)
        if (now.parity[k] != (k < img.parity.size() ? img.parity[k] : 0)) return false;
    return true;
}

void Fasm::write(const Bram& b, const Image& img) {
    if (img.data_bits != b.data_bits())
        die(b.key() + ": image is " + std::to_string(img.data_bits) + " bits wide, the port " + std::to_string(b.data_bits()));
    if ((int)img.data.size() > b.depth())
        die(b.key() + ": " + std::to_string(img.data.size()) + " words do not fit " + std::to_string(b.depth()));
    Tile& t = tiles.at(b.tile);
    const bool is36 = b.half < 0;
    Bits bits;
    bits.data.assign(is36 ? 32768 : 16384, false);
    bits.parity.assign(is36 ? 4096 : 2048, false);
    for (size_t k = 0; k < img.data.size(); k++) {
        for (int i = 0; i < img.data_bits; i++) bits.data[k * img.data_bits + i] = (img.data[k] >> i) & 1;
        if (b.parity_bits() && k < img.parity.size())
            for (int j = 0; j < b.parity_bits(); j++) bits.parity[k * b.parity_bits() + j] = (img.parity[k] >> j) & 1;
    }
    // a line is written when it was in the file before or a bit of it is now set; for a RAMB36E1 that is a bit of
    // either parameter line feeding the half's line, as nextpnr decides it
    auto any = [](const vector<bool>& v, size_t L) {
        for (size_t i = L * 256; i < L * 256 + 256; i++) if (v[i]) return true;
        return false;
    };
    if (is36) {
        for (int h = 0; h < 2; h++) {
            Half& H = t.half[h];
            for (int n = 0; n < 64; n++) {
                for (int j = 0; j < 2; j++)
                    for (int bb = h; bb < 256; bb += 2) H.init[n][j * 128 + bb / 2] = bits.data[(2 * n + j) * 256 + bb];
                H.has_init[n] = H.has_init[n] || any(bits.data, 2 * n) || any(bits.data, 2 * n + 1);
            }
            for (int n = 0; n < 8; n++) {
                for (int j = 0; j < 2; j++)
                    for (int bb = h; bb < 256; bb += 2) H.initp[n][j * 128 + bb / 2] = bits.parity[(2 * n + j) * 256 + bb];
                H.has_initp[n] = H.has_initp[n] || any(bits.parity, 2 * n) || any(bits.parity, 2 * n + 1);
            }
        }
    } else {
        Half& H = t.half[b.half];
        for (int n = 0; n < 64; n++) {
            for (int bb = 0; bb < 256; bb++) H.init[n][bb] = bits.data[n * 256 + bb];
            H.has_init[n] = H.has_init[n] || any(bits.data, n);
        }
        for (int n = 0; n < 8; n++) {
            for (int bb = 0; bb < 256; bb++) H.initp[n][bb] = bits.parity[n * 256 + bb];
            H.has_initp[n] = H.has_initp[n] || any(bits.parity, n);
        }
    }
    t.modified = true;
}

static void emit_half(std::ostream& out, const string& tile, int h, const Half& H) {
    auto vec = [&](const char* name, int n, const std::array<bool, 256>& v) {
        out << tile << ".RAMB18_Y" << h << '.' << name << '_';
        char idx[4];
        snprintf(idx, sizeof idx, "%02X", n);
        out << idx << "[255:0] = 256'b";
        for (int k = 255; k >= 0; k--) out << (v[k] ? '1' : '0');
        out << '\n';
    };
    for (int n = 0; n < 64; n++) if (H.has_init[n]) vec("INIT", n, H.init[n]);
    for (int n = 0; n < 8; n++) if (H.has_initp[n]) vec("INITP", n, H.initp[n]);
}

void Fasm::save(const string& out_path) const {
    std::ofstream out(out_path, std::ios::binary);
    if (!out) die("cannot write " + out_path);
    for (size_t i = 0; i < lines.size(); i++) {
        const string& line = lines[i];
        const Tile* t = nullptr;
        size_t dot = string::npos;
        if (starts(line, "BRAM_")) {
            dot = line.find('.');
            if (dot != string::npos) {
                auto it = tiles.find(line.substr(0, dot));
                if (it != tiles.end() && it->second.modified) t = &it->second;
            }
        }
        if (t) {
            int h, idx;
            bool parity;
            if (init_line(line, dot + 1, h, parity, idx)) continue;
        }
        out << line << '\n';
        if (t)
            for (int h = 0; h < 2; h++)
                if (t->half[h].last_line == (long)i) emit_half(out, t->name, h, t->half[h]);
    }
    if (!out) die("writing " + out_path + " failed");
}

std::vector<uint8_t> read_bytes(const string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) die("cannot open " + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static Image from_words(vector<uint64_t> words, const Bram& b, const string& what) {
    Image img;
    img.data_bits = b.data_bits();
    img.parity_bits = b.parity_bits();
    if ((int)words.size() > b.depth())
        die(what + ": " + std::to_string(words.size()) + " words, the block RAM holds " + std::to_string(b.depth()));
    const uint64_t mask = img.data_bits >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << img.data_bits) - 1);
    for (size_t k = 0; k < words.size(); k++)
        if (words[k] & ~mask) {
            char buf[80];
            snprintf(buf, sizeof buf, ": word %zu (0x%llx) is wider than %d bits", k, (unsigned long long)words[k], img.data_bits);
            die(what + buf);
        }
    words.resize(b.depth(), 0);
    img.data = std::move(words);
    if (img.parity_bits) img.parity.assign(b.depth(), 0);
    return img;
}

Image load_image(const string& path, const Bram& b) {
    const size_t dot = path.rfind('.');
    string ext = dot == string::npos ? "" : path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    vector<uint64_t> words;
    if (ext == "hex" || ext == "mem" || ext == "txt") {
        std::ifstream f(path);
        if (!f) die("cannot open " + path);
        std::map<size_t, uint64_t> at;
        size_t addr = 0;
        string line;
        while (std::getline(f, line)) {
            const size_t c = line.find("//");
            if (c != string::npos) line.erase(c);
            std::istringstream ss(line);
            string tok;
            while (ss >> tok) {
                if (tok[0] == '@') { addr = strtoull(tok.c_str() + 1, nullptr, 16); continue; }
                char* end = nullptr;
                const uint64_t w = strtoull(tok.c_str(), &end, 16);
                if (*end) die(path + ": not a hex word: " + tok);
                at[addr++] = w;
            }
        }
        if (!at.empty()) {
            words.assign(at.rbegin()->first + 1, 0);
            for (auto& kv : at) words[kv.first] = kv.second;
        }
    } else {
        const vector<uint8_t> bytes = read_bytes(path);
        const int wb = (b.data_bits() + 7) / 8;
        for (size_t k = 0; k * wb < bytes.size(); k++) {
            uint64_t w = 0;
            for (int i = 0; i < wb && k * wb + i < bytes.size(); i++) w |= (uint64_t)bytes[k * wb + i] << (8 * i);
            words.push_back(w);
        }
    }
    return from_words(std::move(words), b, path);
}

Image lane_of(const vector<uint8_t>& bytes, int lane, int line_size, const Bram& b) {
    const int wb = (b.data_bits() + 7) / 8;
    if ((lane + 1) * wb > line_size) die("lane " + std::to_string(lane) + " is past a " + std::to_string(line_size) + "-byte line");
    vector<uint64_t> words;
    for (size_t k = 0; k * line_size + lane * wb < bytes.size(); k++) {
        uint64_t w = 0;
        for (int i = 0; i < wb; i++) {
            const size_t at = k * line_size + lane * wb + i;
            if (at < bytes.size()) w |= (uint64_t)bytes[at] << (8 * i);
        }
        words.push_back(w);
    }
    return from_words(std::move(words), b, "lane " + std::to_string(lane));
}

string hex_dump(const Image& img, size_t max_words) {
    std::ostringstream out;
    const int digits = (img.data_bits + 3) / 4;
    const size_t per_line = digits <= 2 ? 32 : digits <= 4 ? 16 : 8;
    const size_t n = max_words ? std::min(max_words, img.data.size()) : img.data.size();
    char buf[48];
    for (size_t k = 0; k < n; k++) {
        if (k % per_line == 0) { snprintf(buf, sizeof buf, "%s%05zx:", k ? "\n" : "", k); out << buf; }
        snprintf(buf, sizeof buf, " %0*llx", digits, (unsigned long long)img.data[k]);
        out << buf;
        if (img.parity_bits && img.parity[k]) { snprintf(buf, sizeof buf, "/%llx", (unsigned long long)img.parity[k]); out << buf; }
    }
    if (n) out << '\n';
    if (n < img.data.size()) out << "... " << (img.data.size() - n) << " more words\n";
    return out.str();
}

// ---- the memories the synthesis made ----

const Memory* Manifest::find(const string& name) const {
    for (const Memory& m : memories) if (m.name == name) return &m;
    return nullptr;
}

static int num(const minijson::JV& o, const char* key, int dflt = 0) {
    const minijson::JV* v = o.get(key);
    return v && v->t == minijson::JV::Num ? (int)v->n : dflt;
}
static string text(const minijson::JV& o, const char* key) {
    const minijson::JV* v = o.get(key);
    return v && v->t == minijson::JV::Str ? v->s : string();
}

Manifest load_manifest(const string& path) {
    const minijson::JV doc = minijson::json_file(path);
    const minijson::JV* mems = doc.get("memories");
    if (!mems || mems->t != minijson::JV::Arr) die(path + ": no \"memories\" (written by verilator --map-only-meminit)");
    Manifest man;
    man.path = path;
    man.top = text(doc, "top");
    for (const minijson::JV& e : mems->a) {
        Memory m;
        m.name = text(e, "name");
        m.type = text(e, "type");
        m.kind = text(e, "kind");
        m.primitive = text(e, "primitive");
        m.init_file = text(e, "init_file");
        m.init_path = text(e, "init_path");
        m.width = num(e, "width");
        m.depth = num(e, "depth");
        m.lane_bits = num(e, "lane_bits");
        m.lanes = num(e, "lanes");
        m.blocks = num(e, "blocks");
        m.words_per_block = num(e, "words_per_block");
        const minijson::JV* cas = e.get("cascade");
        m.cascade = cas && cas->t == minijson::JV::Bool && cas->n != 0;
        const minijson::JV* cells = e.get("cells");
        if (cells && cells->t == minijson::JV::Arr)
            for (const minijson::JV& c : cells->a) {
                MemCell mc;
                mc.cell = text(c, "cell");
                mc.lane = num(c, "lane");
                mc.block = num(c, "block");
                mc.bit_lo = num(c, "bit_lo");
                mc.bits = num(c, "bits");
                mc.word_lo = num(c, "word_lo");
                m.cells.push_back(std::move(mc));
            }
        man.memories.push_back(std::move(m));
    }
    return man;
}

vector<uint64_t> load_words(const string& path, int width, int depth) {
    const size_t dot = path.rfind('.');
    string ext = dot == string::npos ? "" : path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    vector<uint64_t> words;
    if (ext == "hex" || ext == "mem" || ext == "init" || ext == "txt") {   // $readmemh, as the mapper reads it
        std::ifstream f(path);
        if (!f) die("cannot open " + path);
        size_t addr = 0;
        string line, tok;
        while (std::getline(f, line)) {
            const size_t c = line.find("//");
            if (c != string::npos) line.erase(c);
            std::istringstream ss(line);
            while (ss >> tok) {
                if (tok[0] == '@') { addr = strtoull(tok.c_str() + 1, nullptr, 16); continue; }
                uint64_t w = 0;
                for (const char ch : tok) {
                    if (ch == '_') continue;
                    if (!isxdigit((unsigned char)ch)) die(path + ": not a hex word: " + tok);
                    w = (w << 4) | (uint64_t)(isdigit((unsigned char)ch) ? ch - '0' : tolower(ch) - 'a' + 10);
                }
                if (words.size() <= addr) words.resize(addr + 1, 0);
                words[addr++] = w;
            }
        }
    } else {
        const vector<uint8_t> bytes = read_bytes(path);
        const int wb = (width + 7) / 8;
        for (size_t k = 0; k * wb < bytes.size(); k++) {
            uint64_t w = 0;
            for (int i = 0; i < wb && k * wb + i < bytes.size(); i++) w |= (uint64_t)bytes[k * wb + i] << (8 * i);
            words.push_back(w);
        }
    }
    if ((int)words.size() > depth)
        die(path + ": " + std::to_string(words.size()) + " words, the memory holds " + std::to_string(depth));
    const uint64_t mask = width >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << width) - 1);
    for (size_t k = 0; k < words.size(); k++)
        if (words[k] & ~mask) {
            char buf[80];
            snprintf(buf, sizeof buf, ": word %zu (0x%llx) is wider than %d bits", k, (unsigned long long)words[k], width);
            die(path + buf);
        }
    words.resize(depth, 0);
    return words;
}

const Bram* bram_of(const Fasm& f, const MemCell& c) {
    for (const Bram& b : f.brams) if (b.cell == c.cell) return &b;
    return nullptr;
}

Image cell_image(const Memory& m, const MemCell& c, const vector<uint64_t>& words, const Bram& b) {
    Image img;
    img.data_bits = b.data_bits();
    img.parity_bits = b.parity_bits();
    if (img.data_bits < c.bits)
        die(c.cell + ": the block RAM is x" + std::to_string(img.data_bits) + " but the memory " + m.name + " puts " +
            std::to_string(c.bits) + " bits of each word in it");
    const uint64_t mask = c.bits >= 64 ? ~(uint64_t)0 : (((uint64_t)1 << c.bits) - 1);
    img.data.assign(b.depth(), 0);
    for (int k = 0; k < b.depth(); k++) {
        const size_t w = (size_t)c.word_lo + k;
        if (w >= words.size() || k >= m.words_per_block) break;
        img.data[k] = (words[w] >> c.bit_lo) & mask;
    }
    if (img.parity_bits) img.parity.assign(b.depth(), 0);
    return img;
}

RomResult update_memory(Fasm& f, const Memory& m, const vector<uint64_t>& words, bool apply) {
    RomResult r;
    for (const MemCell& c : m.cells) {
        r.cells++;
        const Bram* b = bram_of(f, c);
        if (!b) { if (r.missing.size() < 8) r.missing.push_back(c.cell); continue; }
        r.placed++;
        const Image img = cell_image(m, c, words, *b);
        if (f.same(*b, img)) continue;
        r.changed++;
        if (apply) f.write(*b, img);
    }
    return r;
}

// ---- the command line ----

static int tool_main(int argc, char** argv) {
    string fasm, placement, out_path, cell_re, hexdir, split, dump, meminit;
    vector<std::pair<string, string>> roms;
    bool list_roms = false;
    vector<std::pair<string, string>> sets;
    bool list = false, check = false;
    int line_size = 0;
    for (int i = 1; i < argc; i++) {
        const string a = argv[i];
        auto val = [&]() -> string { if (i + 1 >= argc) die("missing value for " + a); return argv[++i]; };
        if (a == "--fasm") fasm = val();
        else if (a == "--placement") placement = val();
        else if (a == "--out") out_path = val();
        else if (a == "--list") list = true;
        else if (a == "--check") check = true;
        else if (a == "--dump") dump = val();
        else if (a == "--cell") cell_re = val();
        else if (a == "--hexdir") hexdir = val();
        else if (a == "--split") split = val();
        else if (a == "--line-size") line_size = atoi(val().c_str());
        else if (a == "--meminit") meminit = val();
        else if (a == "--roms") list_roms = true;
        else if (a == "--rom") {
            const string kv = val();
            const size_t eq = kv.find('=');
            roms.emplace_back(kv.substr(0, eq), eq == string::npos ? string() : kv.substr(eq + 1));
        } else if (a == "--set") {
            const string kv = val();
            const size_t eq = kv.find('=');
            if (eq == string::npos) die("--set wants KEY=image");
            sets.emplace_back(kv.substr(0, eq), kv.substr(eq + 1));
        } else die("unknown option " + a + " (see the comment at the top of tools/bram_init/bram_init.cpp)");
    }
    if (fasm.empty()) die("--fasm is required");
    Fasm f;
    f.load(fasm);
    if (!placement.empty()) f.name_cells(placement);
    if (list) {
        toolio::out("%-18s %-10s %5s %6s %6s  %s\n", "tile", "block", "width", "depth", "lines", "cell");
        for (const Bram& b : f.brams) {
            const Tile& t = f.tiles.at(b.tile);
            int n = 0;
            for (int h = 0; h < 2; h++) {
                if (b.half >= 0 && h != b.half) continue;
                for (bool x : t.half[h].has_init) n += x;
                for (bool x : t.half[h].has_initp) n += x;
            }
            toolio::out("%-18s %-10s %5d %6d %6d  %s\n", b.tile.c_str(), b.half < 0 ? "RAMB36E1" : (b.half ? "RAMB18_Y1" : "RAMB18_Y0"),
                        b.port_width, b.depth(), n, b.cell.c_str());
        }
    }
    if (!dump.empty()) {
        const Bram* b = f.find(dump);
        if (!b) die("no block RAM " + dump);
        toolio::out("%s", hex_dump(f.read(*b)).c_str());
    }
    // what each block RAM should hold
    vector<std::pair<const Bram*, Image>> wanted;
    for (auto& kv : sets) {
        const Bram* b = f.find(kv.first);
        if (!b) die("no block RAM " + kv.first);
        wanted.emplace_back(b, load_image(kv.second, *b));
    }
    if (!cell_re.empty()) {
        if (hexdir.empty() == split.empty()) die("--cell wants --hexdir or --split");
        if (!split.empty() && line_size <= 0) die("--split wants --line-size");
        if (placement.empty()) die("--cell needs --placement for the cell names");
        const std::regex re(cell_re);
        vector<uint8_t> flat;
        if (!split.empty()) flat = read_bytes(split);
        int matched = 0;
        for (const Bram& b : f.brams) {
            std::smatch m;
            if (b.cell.empty() || !std::regex_match(b.cell, m, re)) continue;
            if (m.size() < 2) die("--cell regex needs a group for the lane number");
            const int lane = atoi(m[1].str().c_str());
            matched++;
            if (!hexdir.empty()) {
                char name[32];
                snprintf(name, sizeof name, "/lane%02d.hex", lane);
                wanted.emplace_back(&b, load_image(hexdir + name, b));
            } else wanted.emplace_back(&b, lane_of(flat, lane, line_size, b));
        }
        if (!matched) die("no placed block RAM cell matches " + cell_re);
    }
    // whole memories, from the synthesis manifest
    int rom_cells = 0, rom_changed = 0;
    if (!meminit.empty() || !roms.empty() || list_roms) {
        if (meminit.empty()) die("--rom and --roms need --meminit");
        const Manifest man = load_manifest(meminit);
        if (list_roms)
            for (const Memory& m : man.memories) {
                int placed = 0;
                for (const MemCell& c : m.cells) placed += bram_of(f, c) != nullptr;
                toolio::out("%-40s %5d x %-7d %-6s %4d/%-4zu cells  %s\n", m.name.c_str(), m.width, m.depth, m.kind.c_str(), placed,
                            m.cells.size(), m.init_file.c_str());
            }
        vector<std::pair<const Memory*, string>> todo;
        for (auto& kv : roms) {
            if (kv.first == "all") {
                for (const Memory& m : man.memories) if (!m.init_path.empty() && kv.second.empty()) todo.emplace_back(&m, m.init_path);
                continue;
            }
            const Memory* m = man.find(kv.first);
            if (!m) die("no memory " + kv.first + " in " + meminit);
            const string img = kv.second.empty() ? m->init_path : kv.second;
            if (img.empty()) die("memory " + kv.first + " has no $readmemh file: give --rom " + kv.first + "=image");
            todo.emplace_back(m, img);
        }
        for (auto& t : todo) {
            const vector<uint64_t> words = load_words(t.second, t.first->width, t.first->depth);
            const RomResult r = update_memory(f, *t.first, words, !check);
            rom_cells += r.cells;
            rom_changed += r.changed;
            toolio::out("%-40s %d cells, %d placed, %d %s  (%s)\n", t.first->name.c_str(), r.cells, r.placed, r.changed,
                        check ? "differ" : "changed", t.second.c_str());
            if (r.placed < r.cells) {
                string miss;
                for (const string& c : r.missing) miss += " " + c;
                toolio::err("  %d cells not in the placement:%s\n", r.cells - r.placed, miss.c_str());
                if (r.placed == 0) die("none of the memory's cells are in the FASM/placement: is --placement the one of this FASM?");
            }
        }
        if (check && !todo.empty()) {
            toolio::out("%d block RAMs differ from the images\n", rom_changed);
            if (wanted.empty()) return rom_changed ? 1 : 0;
        }
        if (!todo.empty() && wanted.empty() && !check) {
            if (!out_path.empty()) {
                f.save(out_path);
                toolio::out("%s: %d block RAMs changed\n", out_path.c_str(), rom_changed);
            } else toolio::out("%d block RAMs would change (no --out)\n", rom_changed);
            return 0;
        }
    }
    int differ = 0;
    for (auto& w : wanted) {
        const bool same = f.same(*w.first, w.second);
        if (!same) differ++;
        if (check) toolio::out("%-40s %s\n", w.first->key().c_str(), same ? "unchanged" : "differs");
        else if (!same) f.write(*w.first, w.second);
    }
    if (check) {
        toolio::out("%zu block RAMs, %d differ from the images\n", wanted.size(), differ);
        return differ ? 1 : 0;
    }
    if (!out_path.empty()) {
        f.save(out_path);
        toolio::out("%s: %zu block RAMs updated, %d changed\n", out_path.c_str(), wanted.size(), differ);
    } else if (!wanted.empty()) toolio::out("%zu block RAMs, %d would change (no --out)\n", wanted.size(), differ);
    return 0;
}

}  // namespace bram_init

int bram_init_main(int argc, char** argv) {
    try {
        return bram_init::tool_main(argc, argv);
    } catch (const toolio::Exit& e) {
        return e.code;
    } catch (const std::exception& e) {
        toolio::err("bram-init: %s\n", e.what());
        return 1;
    }
}
