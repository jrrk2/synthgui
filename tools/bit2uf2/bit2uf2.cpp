// bit2uf2 -- wrap a bitstream in UF2 blocks for the lowRISC Sonata board's SONATA drive (xc7/bit2uf2.py in C++).
//
//   synthgui --tool bit2uf2 in.bit out.bit.slot1.uf2 [--slot 1|2|3]
//
// Same as sonata-system's  uf2conv -b <slot base> -f 0x6ce29e6b in.bit -co out.uf2  (slot bases 0x00000000,
// 0x10000000, 0x20000000). The slot is also picked by the bitstream switch on the board.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include "../common/toolio.hpp"

static void put32(std::string& s, uint32_t v) { for (int i = 0; i < 4; i++) s += (char)(v >> (8 * i)); }

int bit2uf2_main(int argc, char** argv) {
    int slot = 1;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--slot") && i + 1 < argc) slot = atoi(argv[++i]);
        else pos.push_back(argv[i]);
    }
    if (pos.size() != 2 || slot < 1 || slot > 3) { toolio::err("usage: synthgui --tool bit2uf2 in.bit out.uf2 [--slot 1|2|3]\n"); return 2; }
    std::ifstream in(pos[0], std::ios::binary);
    if (!in) { toolio::err("bit2uf2: cannot open %s\n", pos[0].c_str()); return 1; }
    std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const uint32_t FAMILY = 0x6CE29E6B, PAYLOAD = 256;
    const uint32_t base[] = {0, 0x00000000, 0x10000000, 0x20000000};
    uint32_t n = (uint32_t)((data.size() + PAYLOAD - 1) / PAYLOAD);
    std::string out;
    out.reserve((size_t)n * 512);
    for (uint32_t i = 0; i < n; i++) {
        std::string chunk = data.substr((size_t)i * PAYLOAD, PAYLOAD);
        chunk.resize(476, '\0');
        for (uint32_t v : {0x0A324655u, 0x9E5D5157u, 0x2000u, base[slot] + i * PAYLOAD, PAYLOAD, i, n, FAMILY}) put32(out, v);
        out += chunk;
        put32(out, 0x0AB16F30);
    }
    std::ofstream o(pos[1], std::ios::binary);
    o.write(out.data(), (std::streamsize)out.size());
    if (!o) { toolio::err("bit2uf2: cannot write %s\n", pos[1].c_str()); return 1; }
    toolio::out("%s: %u blocks, slot %d\n", pos[1].c_str(), n, slot);
    return 0;
}
