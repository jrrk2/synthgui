// fpeq's stable_sort loop, bare metal in machine mode.  Console and exit are uncached writes.
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <new>
#include <algorithm>
extern "C" void _start();
__asm__(R"(
.section .text.init,"ax"
.globl _start
.option norvc
_start:
  lui t0, %hi(1f)
  addi t0, t0, %lo(1f)
  jr t0
1:
  li t0, 0x6000
  csrs mstatus, t0
  la sp, _stack
  call main
  li t0, 0xf0000008
  sw a0, 0(t0)
2: j 2b
.option rvc
.text
)");
static volatile uint32_t *const CON = (volatile uint32_t *)0xf0000000;
static void putc_(char c) { *CON = (uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void hex(uint64_t v, int n = 16) { while (n--) putc_("0123456789abcdef"[(v >> (n * 4)) & 15]); }
static void dec(long v) { char b[16]; int n = 0; if (!v) b[n++] = '0'; while (v) { b[n++] = '0' + v % 10; v /= 10; } while (n--) putc_(b[n]); }
static char heap[1 << 20]; static size_t hp;
void *operator new(size_t n, const std::nothrow_t &) noexcept { n = (n + 15) & ~15u; hp = (hp + n) % sizeof heap; return heap + hp - n; }
void operator delete(void *) noexcept {}
void operator delete(void *, size_t) noexcept {}
static uint64_t st = 88172645463325252ULL;
static uint64_t rnd() { st ^= st << 13; st ^= st >> 7; st ^= st << 17; return st; }
static double fromu(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static uint64_t ud(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double mkd() { uint64_t r = rnd(); uint64_t e = 1023 - 8 + (r >> 52) % 16; return fromu(((r >> 63) << 63) | (e << 52) | (rnd() >> 12)); }
static double v[302];
int main() {
    puts_("start\n");
    long b1 = 0, b2 = 0, b3 = 0; int shown = 0;
    for (int t = 0; t < 3000; t++) {
        int n = 2 + rnd() % 300;
        for (int i = 0; i < n; i++) v[i] = mkd() * 0.25 + (double)(rnd() % 40);
        std::stable_sort(v, v + n, [](double p, double q) { return p < q; });
        for (int i = 1; i < n; i++) {
            // the board binary's exact sequence (fpeq.dis 0x10974): four loads, then the compares
            int r_lo, r_hi, r_g; double *s0 = &v[i - 1], *s8 = &v[0], *a5p = &v[n - 1];
            __asm__ volatile(
                "fld fa5,8(%[s0])\n fld fa4,0(%[s8])\n fld fa3,0(%[a5])\n fld fa2,0(%[s0])\n"
                "fle.d %[lo],fa4,fa5\n fle.d %[hi],fa5,fa3\n flt.d %[g],fa5,fa2\n"
                : [lo] "=&r"(r_lo), [hi] "=&r"(r_hi), [g] "=&r"(r_g)
                : [s0] "r"(s0), [s8] "r"(s8), [a5] "r"(a5p)
                : "fa5", "fa4", "fa3", "fa2");
            bool g = r_g, lo = r_lo, hi = r_hi;
            if (g) b1++; if (!lo) b2++; if (!hi) b3++;
            if ((g || !lo || !hi) && shown++ < 8) { puts_("t="); dec(t); puts_(" i="); dec(i); puts_(" n="); dec(n); puts_(" g/lo/hi="); dec(g); dec(lo); dec(hi);
                puts_(" v[i]="); hex(ud(v[i])); puts_(" v[0]="); hex(ud(v[0])); putc_('\n'); }
        }
        if (t % 10 == 0) { puts_("t="); dec(t); puts_(" fails "); dec(b1); putc_(' '); dec(b2); putc_(' '); dec(b3); putc_('\n'); }
    }
    puts_("end "); dec(b1); putc_(' '); dec(b2); putc_(' '); dec(b3); putc_('\n');
    return 0;
}
