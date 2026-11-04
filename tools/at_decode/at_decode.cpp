// at_decode -- xc7/at_decode.py in C++: decode `atread` output of an at_gen block.  Its 16-bit per-path counters are LFSRs
// (x^16+x^14+x^13+x^11, reset state 1), so a printed value is a state, not a count.
//
//   synthgui --tool at-decode <hex or decimal values...>
#include <cstdint>
#include <exception>
#include <string>
#include <vector>
#include "../at_gen/lfsr16.hpp"
#include "../common/pycompat.hpp"
#include "../common/toolio.hpp"

int at_decode_main(int argc, char** argv) {
    std::vector<int32_t> table = at_gen_tool::lfsr16_decode();
    for (int i = 1; i < argc; i++) {
        pycompat::PyInt v = pycompat::parse_int(argv[i], 0);
        if (!v.ok) {
            toolio::err("at_decode: invalid literal for int() with base 0: '%s'\n", argv[i]);
            return 1;
        }
        uint32_t s = (uint32_t)(v.neg ? 0 - v.low : v.low) & 0xFFFF;    // int(v, 0) & 0xFFFF, two's complement as in Python
        if (table[s] >= 0) toolio::out("%s -> %d\n", argv[i], table[s]);
        else toolio::out("%s -> not a reachable state (0 = never reset?)\n", argv[i]);
    }
    return 0;
}
