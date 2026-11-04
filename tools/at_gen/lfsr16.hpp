// The per-path counters of an at_gen block are LFSRs (x^16+x^14+x^13+x^11, reset state 1): at_gen.py's lfsr16_decode().
#pragma once
#include <cstdint>
#include <vector>

namespace at_gen_tool {

// state -> number of steps from the reset state 1; -1 for a state the LFSR never reaches
inline std::vector<int32_t> lfsr16_decode() {
    std::vector<int32_t> table(65536, -1);
    uint32_t s = 1;
    for (int32_t k = 0; k < 65535; k++) {
        table[s] = k;
        uint32_t fbit = ((s >> 15) ^ (s >> 13) ^ (s >> 12) ^ (s >> 10)) & 1;
        s = ((s << 1) & 0xFFFF) | fbit;
    }
    return table;
}

}  // namespace at_gen_tool
