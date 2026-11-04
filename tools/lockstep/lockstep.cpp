// Gold (RTL) and gate (mapped netlist) on one memory model, stepped together.
// The slave answers from gold's bus; both see the same inputs; the first differing output stops the run.
//   lockstep prog.bin [--max N] [--seed S] [--no-stop] [--trace-from A --trace-to B --trace-dir D]
#include "Vgold.h"
#include "Vgate.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::vector<uint8_t> ram(64 << 20);
static uint64_t rd64(uint32_t a) { uint64_t v; memcpy(&v, &ram[(a & ~7u) & (ram.size() - 1)], 8); return v; }
static void wr64(uint32_t a, uint64_t d, unsigned sel) {
    uint8_t *p = &ram[(a & ~7u) & (ram.size() - 1)];
    for (int i = 0; i < 8; i++) if (sel >> i & 1) p[i] = d >> (8 * i);
}
template <class T> static void tie(T *m) {
    m->interrupts = 0; m->debugPort_tdi = 0; m->debugPort_enable = 0; m->debugPort_capture = 0; m->debugPort_shift = 0;
    m->debugPort_update = 0; m->debugPort_reset = 0; m->clintWishbone_CYC = 0; m->clintWishbone_STB = 0; m->clintWishbone_WE = 0;
    m->clintWishbone_ADR = 0; m->clintWishbone_DAT_MOSI = 0; m->plicWishbone_CYC = 0; m->plicWishbone_STB = 0; m->plicWishbone_WE = 0;
    m->plicWishbone_ADR = 0; m->plicWishbone_DAT_MOSI = 0; m->peripheral_ERR = 0; m->jtag_clk = 0;
}
int main(int argc, char **argv) {
    uint64_t maxc = 2000000000ULL, tfrom = ~0ULL, tto = ~0ULL; uint32_t seed = 1; bool nostop = false; int lat = 0; bool pstb = false; std::string tdir = ".";
    const char *prog = argv[1];
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--max")) maxc = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--seed")) seed = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--no-stop")) nostop = true;
        else if (!strcmp(argv[i], "--lat")) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace-from")) tfrom = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--trace-to")) tto = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--trace-dir")) tdir = argv[++i];
    }
    FILE *f = fopen(prog, "rb"); if (!f) { perror(prog); return 2; } size_t n = fread(ram.data(), 1, ram.size(), f); fclose(f);
    printf("loaded %zu bytes\n", n);

    // one context per model: a shared context traces every model into every file
    auto *cg = new VerilatedContext, *cx = new VerilatedContext; cg->traceEverOn(true); cx->traceEverOn(true);
    auto *g = new Vgold(cg); auto *x = new Vgate(cx); tie(g); tie(x);
    VerilatedVcdC *tg = nullptr, *tx = nullptr;
    uint64_t cyc = 0, diffs = 0, beats = 0; int wait = 0; bool done = false; int rc = 0;
    uint32_t lf = seed * 2654435761u | 1;
    auto rnd = [&]() { lf ^= lf << 13; lf ^= lf >> 17; lf ^= lf << 5; return lf; };
    auto tick = [&](int clk) {
        g->debugCd_external_clk = clk; x->debugCd_external_clk = clk;
        g->eval(); x->eval();
        if (tg) { tg->dump(cyc * 2 + clk); tx->dump(cyc * 2 + clk); }
    };
    for (; cyc < maxc && !done; cyc++) {
        if (cyc == tfrom) {
            tg = new VerilatedVcdC; tx = new VerilatedVcdC; g->trace(tg, 99); x->trace(tx, 99);
            tg->open((tdir + "/gold.vcd").c_str()); tx->open((tdir + "/gate.vcd").c_str());
        }
        if (cyc == tto && tg) { tg->close(); tx->close(); tg = tx = nullptr; }
        bool rst = cyc < 64;
        g->debugCd_external_reset = rst; x->debugCd_external_reset = rst;
        // low phase: answer gold's bus
        g->debugCd_external_clk = 0; x->debugCd_external_clk = 0; g->eval(); x->eval();
        bool stb = g->peripheral_CYC && g->peripheral_STB;
        if (stb && !pstb) wait += lat;
        pstb = stb;
        bool ack = stb && wait == 0;
        uint64_t dr = 0xdeadbeefcafef00dULL;
        uint32_t adr = (uint32_t)g->peripheral_ADR << 3;
        if (ack && !g->peripheral_WE) dr = (adr >> 28) == 0xf ? 0 : rd64(adr);
        g->peripheral_ACK = ack; x->peripheral_ACK = ack; g->peripheral_DAT_MISO = dr; x->peripheral_DAT_MISO = dr;
        tick(0);
        // compare the bus: the qualifiers always, the payload under STB
        bool d = g->peripheral_CYC != x->peripheral_CYC || g->peripheral_STB != x->peripheral_STB;
        if (stb && !d) d = g->peripheral_WE != x->peripheral_WE || g->peripheral_ADR != x->peripheral_ADR || g->peripheral_SEL != x->peripheral_SEL
                         || g->peripheral_CTI != x->peripheral_CTI || g->peripheral_BTE != x->peripheral_BTE
                         || (g->peripheral_WE && g->peripheral_DAT_MOSI != x->peripheral_DAT_MOSI);
        if (d && cyc >= 64) {
            diffs++;
            printf("\nDIFF cycle %llu ack=%d\n gold cyc=%d stb=%d we=%d adr=%08x sel=%02x cti=%d bte=%d dat=%016llx\n gate cyc=%d stb=%d we=%d adr=%08x sel=%02x cti=%d bte=%d dat=%016llx\n",
                   (unsigned long long)cyc, ack, g->peripheral_CYC, g->peripheral_STB, g->peripheral_WE, (uint32_t)g->peripheral_ADR << 3, g->peripheral_SEL, g->peripheral_CTI, g->peripheral_BTE, (unsigned long long)g->peripheral_DAT_MOSI,
                   x->peripheral_CYC, x->peripheral_STB, x->peripheral_WE, (uint32_t)x->peripheral_ADR << 3, x->peripheral_SEL, x->peripheral_CTI, x->peripheral_BTE, (unsigned long long)x->peripheral_DAT_MOSI);
            fflush(stdout);
            if (!nostop) { rc = 1; done = true; }
        }
        if (ack) {
            beats++;
            if (g->peripheral_WE) {
                if ((adr >> 28) == 0xf) {
                    uint32_t a = adr; uint64_t dw = g->peripheral_DAT_MOSI; unsigned sel = g->peripheral_SEL;
                    if (sel & 0xf0) { a += 4; dw >>= 32; }
                    if (a == 0xf0000000) { putchar((int)(dw & 0xff)); fflush(stdout); }
                    else if (a == 0xf0000008) { printf("\nEXIT %u cycle %llu\n", (uint32_t)dw, (unsigned long long)cyc); done = true; }
                    else printf("\nMMIO write %08x %016llx\n", a, (unsigned long long)dw);
                } else wr64(adr, g->peripheral_DAT_MOSI, g->peripheral_SEL);
            }
            uint32_t r = rnd() & 15;   // mostly quick, sometimes slow
            wait = r < 10 ? 0 : r < 14 ? 1 + (r & 1) : 8 + (rnd() & 15);
        } else if (stb) wait--;
        tick(1);
        if ((cyc & 0xffffff) == 0 && cyc) { fprintf(stderr, "cycle %lluM beats %llu\n", (unsigned long long)cyc >> 20, (unsigned long long)beats); }
    }
    if (tg) { tg->close(); tx->close(); }
    printf("\nstopped at cycle %llu, %llu differing cycles, %llu beats\n", (unsigned long long)cyc, (unsigned long long)diffs, (unsigned long long)beats);
    g->final(); x->final();
    return rc;
}
