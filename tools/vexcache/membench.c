// membench: memory-system penalties of this board, from Linux user space, in ns per operation.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static uint32_t rs = 88172645;
static uint32_t rn(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
// a cycle through addresses base + i*stride in random order, then time n loads along it
static double chase(char *base, unsigned count, unsigned stride, unsigned long n) {
    unsigned *o = malloc(count * sizeof *o);
    for (unsigned i = 0; i < count; i++) o[i] = i;
    for (unsigned i = count - 1; i > 0; i--) { unsigned j = rn() % (i + 1), t = o[i]; o[i] = o[j]; o[j] = t; }
    for (unsigned i = 0; i < count; i++) *(void **)(base + o[i] * stride) = base + o[(i + 1) % count] * stride;
    void **p = (void **)(base + o[0] * stride);
    for (unsigned i = 0; i < count; i++) p = (void **)*p;   // warm
    double t0 = now();
    for (unsigned long i = 0; i < n; i += 8) { p = *p; p = *p; p = *p; p = *p; p = *p; p = *p; p = *p; p = *p; }
    double t = now() - t0;
    if (!p) puts("");
    free(o);
    return t / n;
}
#define SLED(N, NAME) __asm__(".text\n.balign 4096\n.globl " #NAME "\n.option push\n.option norvc\n" #NAME ":\n.rept " #N "\n j 1f\n .space 60\n1:\n.endr\n ret\n.option pop\n")
SLED(16, sled1k);    // 1 KB: fits the I cache
SLED(512, sled32k);  // 32 KB: misses every line in 4 KB, reloads from L2, spans 8 pages
SLED(2048, sled128k);// 128 KB+: 32 pages, some misses in L2
extern void sled1k(void), sled32k(void), sled128k(void);
static double loop_taken(void) { double t0 = now(); __asm__ volatile("li t0, 2000000\n1: addi t0, t0, -1\n bnez t0, 1b\n" : : : "t0"); return (now() - t0) / 2e6; }
static double loop_nop(void) { double t0 = now(); __asm__ volatile("li t0, 2000000\n1: addi t0, t0, -1\n .rept 15\n nop\n .endr\n bnez t0, 1b\n" : : : "t0"); return (now() - t0) / 2e6; }
static double loop_nt(void) { double t0 = now(); __asm__ volatile("li t0, 2000000\n li t1, 0\n1: addi t0, t0, -1\n .rept 15\n bnez t1, 2f\n .endr\n bnez t0, 1b\n2:\n" : : : "t0", "t1"); return (now() - t0) / 2e6; }
static double loop_lu(void) { static volatile int v; int *p = (int *)&v; double t0 = now(); __asm__ volatile("li t0, 1000000\n1: addi t0, t0, -1\n .rept 8\n lw t1, 0(%0)\n addi t2, t1, 1\n .endr\n bnez t0, 1b\n" : : "r"(p) : "t0", "t1", "t2"); return (now() - t0) / 1e6; }
static double loop_nlu(void) { static volatile int v; int *p = (int *)&v; double t0 = now(); __asm__ volatile("li t0, 1000000\n1: addi t0, t0, -1\n .rept 8\n lw t1, 0(%0)\n addi t2, t0, 1\n .endr\n bnez t0, 1b\n" : : "r"(p) : "t0", "t1", "t2"); return (now() - t0) / 1e6; }
static double run(void (*f)(void), unsigned jumps, unsigned rep) {
    for (unsigned i = 0; i < 3; i++) f();
    double t0 = now(); for (unsigned i = 0; i < rep; i++) f(); return (now() - t0) / (rep * (double)jumps);
}
int main(void) {
    size_t sz = 256 << 20;
    char *m = mmap(0, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    for (size_t i = 0; i < sz; i += 4096) m[i] = 1;
    char *a = (char *)(((uintptr_t)m + 4095) & ~4095UL);
    printf("l1_hit        %8.1f\n", chase(a, 32, 64, 2000000));          // 2 KB in one page
    printf("l2_hit        %8.1f\n", chase(a, 192, 64, 1000000));         // 12 KB in 3 pages: L1 conflicts, L2 hits, TLB hits
    printf("tlb_l1        %8.1f\n", chase(a, 16, 4096 + 64, 1000000));   // 16 pages, 16 lines that fit in L1
    printf("tlb_l2        %8.1f\n", chase(a, 256, 4096 + 64, 300000));   // 256 pages, L1 conflicts, L2 hits (lines < L2)
    printf("dram          %8.1f\n", chase(a, 60000, 4096 + 64, 100000)); // 60000 lines across 250 MB
    volatile uint32_t *s = (volatile uint32_t *)a;
    double t0 = now();
    for (unsigned long i = 0; i < 1000000; i += 8) { s[0] = i; s[1] = i; s[2] = i; s[3] = i; s[4] = i; s[5] = i; s[6] = i; s[7] = i; }
    printf("store_seq     %8.1f\n", (now() - t0) / 1000000);
    t0 = now();
    for (volatile unsigned long i = 0; i < 2000000; i++) ;
    printf("loop_iter     %8.1f\n", (now() - t0) / 2000000);
    printf("loop_taken    %8.1f\n", loop_taken());
    printf("loop_15nop    %8.1f\n", loop_nop());
    printf("loop_15bnt    %8.1f\n", loop_nt());
    printf("loop_8lu      %8.1f\n", loop_lu());
    printf("loop_8nlu     %8.1f\n", loop_nlu());
    printf("i_hit_jump    %8.1f\n", run(sled1k, 16, 100000));
    printf("i_l2_jump     %8.1f\n", run(sled32k, 512, 2000));
    printf("i_l2m_jump    %8.1f\n", run(sled128k, 2048, 500));
    return 0;
}
