// bram-init -- the block RAMs of a routed 7-series FASM and their contents, so a memory image can be replaced after
// place and route (the open flow's updatemem): only fasm2frames and the bitstream need to run again.
//
// A FASM names each block RAM tile's two RAMB18 halves; a RAMB36E1 uses both with its INIT_xx bits dealt out to them
// alternately (nextpnr's write_bram_init), a RAMB18E1 one half with its INIT_xx as they are. The port width in the FASM
// gives the word layout (UG473: word k's data bits follow each other in INIT_xx, its parity bits in INITP_xx).
//
// Lines of a block RAM that is not changed are written back exactly as read, so an unchanged file comes out identical.
#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace bram_init {

struct Half {                                  // TILE.RAMB18_Yh
    bool in_use = false;
    int read_width_a = 0, read_width_b = 0;    // the _N of READ_WIDTH_A_N, 36 for SDP_READ_WIDTH_36
    int write_width_a = 0, write_width_b = 0;
    std::array<bool, 64> has_init{};           // INIT_xx lines present in the file
    std::array<bool, 8> has_initp{};
    std::array<std::array<bool, 256>, 64> init{};
    std::array<std::array<bool, 256>, 8> initp{};
    long last_line = -1;                       // index of the half's last non-INIT line: new INIT lines go after it
};

struct Tile {
    std::string name;
    bool ramb36 = false;                       // TILE.RAMB36.* features present (nextpnr writes them for odd widths only)
    int mode = 0;                              // 36: one RAMB36E1, 18: RAMB18E1 per half, 0: not known, see is36()
    std::string cell36, cell18[2];             // from the placement JSON
    Half half[2];
    bool modified = false;
    // A FASM alone cannot tell an x36 RAMB36E1 from two x18 RAMB18E1 (the same bits): the placement decides, or the
    // user; failing both, two halves in use with the same widths are taken as one RAMB36E1.
    bool is36() const;
};

// one block RAM as the user sees it: a RAMB36E1 (both halves) or a RAMB18E1 (one half)
struct Bram {
    std::string tile;
    int half = -1;                             // -1: RAMB36E1
    int port_width = 0;                        // 1, 2, 4, 9, 18, 36 or 72 (RAMB36E1), up to 36 for a RAMB18E1
    std::string cell;                          // from the placement JSON, when given
    std::string key() const { return half < 0 ? tile : tile + "/Y" + std::to_string(half); }
    int data_bits() const { return port_width >= 9 ? port_width * 8 / 9 : port_width; }
    int parity_bits() const { return port_width - data_bits(); }
    int depth() const { return (half < 0 ? 32768 : 16384) / data_bits(); }
};

struct Image {                                 // the words of one block RAM
    int data_bits = 0, parity_bits = 0;
    std::vector<uint64_t> data, parity;        // parity empty when the port has none
};

struct Fasm {
    std::string path;
    std::vector<std::string> lines;
    std::map<std::string, Tile> tiles;
    std::vector<std::string> order;            // tiles in file order
    std::vector<Bram> brams;                   // in file order

    void load(const std::string& path);        // throws std::runtime_error
    void name_cells(const std::string& placement_json);   // nextpnr -o placement=: cell names and modes onto the tiles
    void set_mode(const std::string& tile, int mode);     // 36, 18 or 0; rebuilds brams
    void rebuild();                                       // brams from tiles
    const Bram* find(const std::string& key) const;       // "TILE" or "TILE/Y0"
    Image read(const Bram& b) const;
    void write(const Bram& b, const Image& img);          // replaces the block RAM's contents
    bool same(const Bram& b, const Image& img) const;
    void save(const std::string& path) const;
};

// $readmemh text (hex words, @addr, // comments) or, for any other extension, raw little-endian words of the image's
// byte size. Words wider than the port are an error; missing words are 0 up to the depth.
Image load_image(const std::string& path, const Bram& b);
Image lane_of(const std::vector<uint8_t>& bytes, int lane, int line_size, const Bram& b);   // byte lane of a flat image
std::vector<uint8_t> read_bytes(const std::string& path);
std::string hex_dump(const Image& img, size_t max_words = 0);
int width_from_code(int code, bool ramb36);   // FASM width marker -> port width

}  // namespace bram_init
