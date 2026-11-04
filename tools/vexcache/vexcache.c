// QEMU TCG plugin: one run, many VexRiscv memory systems.
// L1 I and D: round-robin ways (VexRiscv's wayToAllocate counter), 64-byte lines. D is write-through, no write-allocate.
// L2 (LiteX wishbone.Cache): direct mapped, 64-byte lines, physically indexed: pages are hashed to approximate that.
// TLBs: fully associative, round-robin (MmuPlugin's entryToReplace), per port. Only user-mode accesses are seen.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <qemu-plugin.h>
QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;
#define LINE 6
typedef struct { unsigned size, ways, sets, rr; uint32_t *tag; uint64_t acc, miss; } L1;
typedef struct { unsigned size, mask; uint32_t *tag; uint64_t ird, drd, wr, irdm, drdm, wrm; } L2;
typedef struct { unsigned n, rr, last; uint32_t *page; uint64_t acc, miss; } TLB;
static const unsigned IS[] = {4, 8, 16, 32, 64}, DS[] = {4, 8, 16, 32, 64}, LS[] = {64, 128, 256, 512, 1024, 2048};
static const unsigned ITLB[] = {2, 4, 8, 16, 32, 64}, DTLB[] = {2, 4, 8, 16, 32, 64, 128, 256};
#define NI (sizeof IS / sizeof *IS)
#define ND (sizeof DS / sizeof *DS)
#define NL (sizeof LS / sizeof *LS)
#define NIT (sizeof ITLB / sizeof *ITLB)
#define NDT (sizeof DTLB / sizeof *DTLB)
static L1 ic[NI], dc[ND];
static L2 l2[NI][ND][NL];
static TLB it[NIT], dt[NDT];
static uint64_t insns, loads, stores, c_insn;
static uint32_t last_iline = ~0u, last_ipage = ~0u;
static const char *out_path = "vexcache.csv";
// control flow and hazards: per instruction, from its encoding
typedef struct { uint32_t pc; uint8_t len, kind, rd, rs1, rs2, isload; } II;
enum { K_OTHER, K_COND, K_JAL, K_JALR };
static II *prev;
static uint64_t n_cond, n_cond_taken, n_jal, n_jalr, n_taken_same_line, n_loaduse;
static uint64_t n_mul, n_div, n_fp;
#define NBTB 4
static const unsigned BTBLOG[NBTB] = {8, 10, 12, 14};
static struct { uint32_t *tag, *tgt; uint8_t *cnt; uint64_t mis, right; } btb[NBTB];
static void btb_step(const II *p, uint32_t next, int taken) {
    for (unsigned b = 0; b < NBTB; b++) {
        uint32_t idx = (p->pc >> 1) & ((1u << BTBLOG[b]) - 1), tag = p->pc;
        int hit = btb[b].tag[idx] == tag;
        int pred = hit && btb[b].cnt[idx] >= 2;
        int ok = pred ? (taken && btb[b].tgt[idx] == next) : !taken;
        if (ok) btb[b].right++; else btb[b].mis++;
        if (!hit) { if (taken) { btb[b].tag[idx] = tag; btb[b].tgt[idx] = next; btb[b].cnt[idx] = 2; } }
        else { if (taken) { if (btb[b].cnt[idx] < 3) btb[b].cnt[idx]++; btb[b].tgt[idx] = next; } else if (btb[b].cnt[idx]) btb[b].cnt[idx]--; }
    }
}

static void l1_init(L1 *c, unsigned kb) { c->size = kb * 1024; c->ways = kb / 4; c->sets = 64; c->tag = malloc(4 * c->ways * c->sets); memset(c->tag, 0xff, 4 * c->ways * c->sets); }
static inline int l1_look(L1 *c, uint32_t line, int fill) {
    uint32_t *s = c->tag + (line & 63) * c->ways;
    for (unsigned w = 0; w < c->ways; w++) if (s[w] == line) return 1;
    if (fill) { s[c->rr] = line; c->rr = (c->rr + 1) % c->ways; }
    return 0;
}
static inline uint32_t phys_line(uint32_t a) {   // hashed page, kept offset
    uint32_t p = a >> 12; p = (p * 0x9E3779B1u) >> 12;
    return (p << 6) | ((a >> LINE) & 63);
}
static inline int l2_look(L2 *c, uint32_t line, uint32_t a) {
    uint32_t idx = phys_line(a) & c->mask;
    if (c->tag[idx] == line) return 1;
    c->tag[idx] = line; return 0;
}
static inline int tlb_look(TLB *t, uint32_t page) {
    if (t->last == page) return 1;
    for (unsigned i = 0; i < t->n; i++) if (t->page[i] == page) { t->last = page; return 1; }
    t->page[t->rr] = page; t->rr = (t->rr + 1) % t->n; t->last = page; t->miss++;
    return 0;
}
static void vcpu_insn(unsigned vcpu, void *ud) {
    II *ii = ud; uint32_t a = ii->pc;
    insns++;
    if (prev) {
        int taken = prev->pc + prev->len != a;
        if (prev->kind == K_COND) { n_cond++; n_cond_taken += taken; btb_step(prev, a, taken); }
        else if (prev->kind == K_JAL) { n_jal++; btb_step(prev, a, 1); }
        else if (prev->kind == K_JALR) { n_jalr++; btb_step(prev, a, 1); }
        if (taken && (prev->pc >> 6) == (a >> 6)) n_taken_same_line++;
        if (prev->isload && prev->rd && (ii->rs1 == prev->rd || ii->rs2 == prev->rd)) n_loaduse++;
    }
    prev = ii;
    uint32_t line = a >> LINE, page = a >> 12;
    if (line != last_iline) {
        last_iline = line;
        for (unsigned i = 0; i < NI; i++) {
            ic[i].acc++;
            if (!l1_look(&ic[i], line, 1)) {
                ic[i].miss++;
                for (unsigned d = 0; d < ND; d++) for (unsigned l = 0; l < NL; l++) {
                    L2 *c = &l2[i][d][l]; c->ird++; if (!l2_look(c, line, a)) c->irdm++;
                }
            }
        }
    }
    if (page != last_ipage) { last_ipage = page; for (unsigned i = 0; i < NIT; i++) { it[i].acc++; tlb_look(&it[i], page); } }
}
static void vcpu_mem(unsigned vcpu, qemu_plugin_meminfo_t info, uint64_t vaddr, void *ud) {
    uint32_t a = (uint32_t)vaddr, line = a >> LINE, page = a >> 12;
    int st = qemu_plugin_mem_is_store(info);
    if (st) stores++; else loads++;
    for (unsigned t = 0; t < NDT; t++) { dt[t].acc++; tlb_look(&dt[t], page); }
    for (unsigned d = 0; d < ND; d++) {
        dc[d].acc++;
        int hit = l1_look(&dc[d], line, !st);
        if (!hit) dc[d].miss += !st;
        if (st || !hit) for (unsigned i = 0; i < NI; i++) for (unsigned l = 0; l < NL; l++) {
            L2 *c = &l2[i][d][l];
            if (st) { c->wr++; if (!l2_look(c, line, a)) c->wrm++; }
            else { c->drd++; if (!l2_look(c, line, a)) c->drdm++; }
        }
    }
}
static void tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb) {
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *in = qemu_plugin_tb_get_insn(tb, i);
        II *ii = calloc(1, sizeof *ii);
        ii->pc = qemu_plugin_insn_vaddr(in); ii->len = qemu_plugin_insn_size(in);
        const uint8_t *dp = qemu_plugin_insn_data(in); uint32_t w = dp[0] | dp[1] << 8; 
        if (ii->len == 4) { w |= (uint32_t)dp[2] << 16 | (uint32_t)dp[3] << 24;
            unsigned op = w & 0x7f; ii->rd = (w >> 7) & 31; ii->rs1 = (w >> 15) & 31; ii->rs2 = (w >> 20) & 31;
            if (op == 0x63) { ii->kind = K_COND; ii->rd = 0; } else if (op == 0x6f) ii->kind = K_JAL; else if (op == 0x67) ii->kind = K_JALR;
            else if (op == 0x03) ii->isload = 1;
            if (op == 0x33 && (w >> 25) == 1) { if (((w >> 12) & 7) < 4) ii->kind = K_OTHER, ii->rs2 |= 0; }
        } else { unsigned q = w & 3, f = w >> 13; 
            ii->rd = (w >> 7) & 31; ii->rs2 = (w >> 2) & 31;
            if (q == 1 && (f == 5 || f == 1)) ii->kind = K_JAL;
            else if (q == 1 && (f == 6 || f == 7)) { ii->kind = K_COND; ii->rd = 0; ii->rs1 = 8 + ((w >> 7) & 7); ii->rs2 = 0; }
            else if (q == 2 && f == 4 && ii->rs2 == 0 && ii->rd) { ii->kind = K_JALR; ii->rs1 = ii->rd; ii->rd = 0; }
            else if (q == 0 && f == 2) { ii->isload = 1; ii->rd = 8 + ((w >> 2) & 7); ii->rs1 = 8 + ((w >> 7) & 7); ii->rs2 = 0; }
            else if (q == 2 && f == 2) { ii->isload = 1; ii->rs1 = 2; ii->rs2 = 0; }
            else if (q == 0) { ii->rs1 = 8 + ((w >> 7) & 7); ii->rs2 = 8 + ((w >> 2) & 7); ii->rd = 0; }
            else ii->rs1 = ii->rd;
        }
        qemu_plugin_register_vcpu_insn_exec_cb(in, vcpu_insn, QEMU_PLUGIN_CB_NO_REGS, ii);
        qemu_plugin_register_vcpu_mem_cb(in, vcpu_mem, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW, NULL);
    }
}
static void at_exit(qemu_plugin_id_t id, void *p) {
    FILE *f = fopen(out_path, "w");
    if (!f) return;
    fprintf(f, "#insns,%" PRIu64 ",loads,%" PRIu64 ",stores,%" PRIu64 "\n", insns, loads, stores);
    fprintf(f, "#cond,%" PRIu64 ",cond_taken,%" PRIu64 ",jal,%" PRIu64 ",jalr,%" PRIu64 ",taken_same_line,%" PRIu64 ",loaduse,%" PRIu64 "\n", n_cond, n_cond_taken, n_jal, n_jalr, n_taken_same_line, n_loaduse);
    for (unsigned b = 0; b < NBTB; b++) fprintf(f, "#btb,%u,mispredict,%" PRIu64 ",right,%" PRIu64 "\n", 1u << BTBLOG[b], btb[b].mis, btb[b].right);
    fprintf(f, "itlb,size,acc,miss\n");
    for (unsigned i = 0; i < NIT; i++) fprintf(f, "itlb,%u,%" PRIu64 ",%" PRIu64 "\n", it[i].n, it[i].acc, it[i].miss);
    for (unsigned i = 0; i < NDT; i++) fprintf(f, "dtlb,%u,%" PRIu64 ",%" PRIu64 "\n", dt[i].n, dt[i].acc, dt[i].miss);
    for (unsigned i = 0; i < NI; i++) fprintf(f, "ic,%u,%" PRIu64 ",%" PRIu64 "\n", IS[i], ic[i].acc, ic[i].miss);
    for (unsigned d = 0; d < ND; d++) fprintf(f, "dc,%u,%" PRIu64 ",%" PRIu64 "\n", DS[d], dc[d].acc, dc[d].miss);
    for (unsigned i = 0; i < NI; i++) for (unsigned d = 0; d < ND; d++) for (unsigned l = 0; l < NL; l++) {
        L2 *c = &l2[i][d][l];
        fprintf(f, "l2,%u,%u,%u,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", IS[i], DS[d], LS[l], c->ird, c->irdm, c->drd, c->drdm, c->wr, c->wrm);
    }
    fclose(f);
}
QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv) {
    for (int i = 0; i < argc; i++) if (!strncmp(argv[i], "out=", 4)) out_path = argv[i] + 4;
    for (unsigned i = 0; i < NI; i++) l1_init(&ic[i], IS[i]);
    for (unsigned d = 0; d < ND; d++) l1_init(&dc[d], DS[d]);
    for (unsigned i = 0; i < NI; i++) for (unsigned d = 0; d < ND; d++) for (unsigned l = 0; l < NL; l++) {
        L2 *c = &l2[i][d][l]; unsigned lines = LS[l] * 1024 / 64;
        c->size = LS[l]; c->mask = lines - 1; c->tag = malloc(4 * lines); memset(c->tag, 0xff, 4 * lines);
    }
    for (unsigned i = 0; i < NIT; i++) { it[i].n = ITLB[i]; it[i].last = ~0u; it[i].page = malloc(4 * ITLB[i]); memset(it[i].page, 0xff, 4 * ITLB[i]); }
    for (unsigned i = 0; i < NDT; i++) { dt[i].n = DTLB[i]; dt[i].last = ~0u; dt[i].page = malloc(4 * DTLB[i]); memset(dt[i].page, 0xff, 4 * DTLB[i]); }
    for (unsigned b = 0; b < NBTB; b++) { unsigned n = 1u << BTBLOG[b]; btb[b].tag = malloc(4 * n); memset(btb[b].tag, 0xff, 4 * n); btb[b].tgt = calloc(n, 4); btb[b].cnt = calloc(n, 1); }
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
