// A floating-point checksum: every result's bits folded in, so one wrong bit anywhere changes the answer.
#include <math.h>
#include <stdint.h>

#include <string.h>
static uint64_t h = 1469598103934665603ULL;
static void mix(double d) { uint64_t u; memcpy(&u, &d, 8); h = (h ^ u) * 1099511628211ULL; }
static void mixf(float f) { uint32_t u; memcpy(&u, &f, 4); h = (h ^ u) * 1099511628211ULL; }

__asm__(".section .text.init,\"ax\"\n.globl _start\n.option push\n.option norvc\n_start:\n lui t0,%hi(1f)\n addi t0,t0,%lo(1f)\n jr t0\n1:\n li t0,0x6000\n csrs mstatus,t0\n la sp,_stack\n call fp_main\n li t0,0xf0000008\n sw a0,0(t0)\n2: j 2b\n.option pop\n.text\n");
static volatile uint32_t *const CON=(volatile uint32_t*)0xf0000000;
static void hx(uint64_t v){const char*p="fpcheck ";while(*p)*CON=*p++;for(int i=15;i>=0;i--)*CON="0123456789abcdef"[(v>>(i*4))&15];*CON='\n';}
int fp_main(void) {
    double x = 1.000000123, y = 0.7071067811865476; float a = 1.0000012f, b = 0.70710677f;
    for (long i = 0; i < 2000000; i++) {
        double d = x * y + (double)(i & 1023) / 1024.0;
        double q = d / (y + 1.5), s = __builtin_sqrt(d + 2.0), f = x * y - d;
        float g = a * b + (float)(i & 255) / 256.0f, r = __builtin_sqrtf(g + 2.0f), t = g / (b + 1.5f);
        mix(d); mix(q); mix(s); mix(f); mixf(g); mixf(r); mixf(t);
        mix((double)(int)(q * 1000.0)); 
        x = 1.0 + (s - (long)s) * 1e-3; y = 0.5 + (q - (long)q) * 0.25; a = 1.0f + (r - (int)r) * 1e-3f; b = 0.5f + (t - (int)t) * 0.25f;
    }
    hx(h);
    return 0;
}
