/* The picture program: shows 160x128 RGB565 pictures on the Sonata's ST7735 LCD from the boot ROM, with no BIOS and no RAM
 * beyond the stack. It runs where the LiteX BIOS would (the reset vector, 0x00000000), so "BIOS mode" is all there is.
 *
 * It shows the picture built into the ROM image (picture.S includes the frame with .incbin), then, when the ROM image carries
 * a list of frames in the SPI flash (photos.S, from `mkrom photos` over the rootfs romfs: the photobox pictures of the ROM
 * Linux), cycles through them every INTERVAL_S seconds, read straight from the flash window (the same 40960-byte raw frames
 * Linux's `photobox` and /dev/fb0 take). Both the built-in picture and the list are plain ROM contents: a new one is a new
 * ROM image, which the ROMs tab of the Block RAMs window (or `bram-init --rom`) writes into the routed FASM and turns into a
 * bitstream in seconds, with no synthesis and no place and route.
 *
 * The Sonata's eight LEDs chase by themselves (LedChaser) until the program writes their control register, so the
 * program turns them off first.
 *
 * The LCD (rtl/lcd_text.v) runs its own ST7735 initialisation after reset, in text mode; the frame buffer is a write-only
 * window of 10240 words, and word 81 of the control window selects it (bit 0).
 */
#include <stdint.h>

#ifndef CSR_BASE
#define CSR_BASE     0xF0000000u               /* the SoC's CSR window; the QEMU test moves it into RAM */
#endif
#ifndef FLASH_BASE
#define FLASH_BASE   0x02000000u               /* the SPI flash, read in place */
#endif
#ifndef CLINT_BASE
#define CLINT_BASE   0xF0010000u               /* mtime is at +0xBFF8, ticking at the system clock: 50 MHz */
#endif
#ifndef TIMEBASE_HZ
#define TIMEBASE_HZ  50000000u
#endif
#ifndef INTERVAL_S
#define INTERVAL_S   8                         /* photobox's own default */
#endif
#ifndef ROUNDS
#define ROUNDS       0                         /* 0: for ever; the QEMU test runs one */
#endif
/* LiteX's LedChaser runs its pattern until the control register is written: bank 4 (gen_soc.v: csrbank1, adr[13:9] == 4), register 0,
 * and each CSR bank is 0x800 bytes. A write switches the LEDs to the register's value. */
#define LEDS_OUT     (CSR_BASE + 4u * 0x800u)

#define LCD_BASE     0x80305000u               /* control window: word 80 scroll, word 81 mode, word 82 test */
#define LCD_FB_BASE  0x80310000u               /* frame buffer: word k holds pixels 2k and 2k+1 */
#define LCD_MODE     (LCD_BASE + 81u * 4u)
#define FB_WORDS     (160u * 128u / 2u)

extern const uint32_t picture_rom[FB_WORDS];   /* picture.S: the built-in frame, .incbin'd */
extern const uint32_t photo_count;             /* photos.S: the frames in the flash ... */
extern const uint32_t photo_offset[];          /* ... as offsets from the start of the flash */

static void show(const volatile uint32_t* src) {
    volatile uint32_t* fb = (volatile uint32_t*)LCD_FB_BASE;
    for (uint32_t k = 0; k < FB_WORDS; k++) fb[k] = src[k];
}

static uint64_t mtime(void) {
    volatile uint32_t* t = (volatile uint32_t*)(CLINT_BASE + 0xBFF8u);
    uint32_t hi, lo;
    do { hi = t[1]; lo = t[0]; } while (hi != t[1]);
    return (uint64_t)hi << 32 | lo;
}

static void wait_s(uint32_t s) {
    const uint64_t until = mtime() + (uint64_t)s * TIMEBASE_HZ;
    while (mtime() < until) { }
}

int main(void) {
    *(volatile uint32_t*)LEDS_OUT = 0;         /* the chaser off: the LEDs are the program's now, and dark */
    show((const volatile uint32_t*)picture_rom);
    *(volatile uint32_t*)LCD_MODE = 1;         /* show it */
    if (!photo_count) return 0;
    for (uint32_t round = 1;; round++) {
        for (uint32_t i = 0; i < photo_count; i++) {
            wait_s(INTERVAL_S);
            show((const volatile uint32_t*)(FLASH_BASE + photo_offset[i]));
        }
#if ROUNDS
        if (round >= ROUNDS) return 0;
#endif
    }
}
