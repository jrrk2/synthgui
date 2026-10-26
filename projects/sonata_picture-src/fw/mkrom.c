/* mkrom: the two small conversions the picture program's build needs.
 *
 *   mkrom frame PICTURE OUT.rgb565   PICTURE is a raw 160x128 RGB565 frame (40960 bytes, little-endian pixels, as /dev/fb0 and
 *                                    tools/img2fb.py take it) or a binary PPM (P6, maxval 255) of any size, scaled to
 *                                    160x128 by nearest neighbour. OUT is the raw frame, which picture.S includes.
 *   mkrom photos ROMFS OUT.S [PREFIX] assembly with the flash offsets of the 160x128 frames in a romfs image (the rootfs the
 *                                    SoC's flash holds at 0x5C0000): every regular .raw file of 40960 bytes whose path starts
 *                                    with PREFIX (default /usr/share/photobox/). No ROMFS ("-") makes an empty list.
 *   mkrom init PROGRAM.bin OUT.init  the flat binary of the linked program and picture as the $readmemh file of the
 *                                    16384-word boot ROM (one hex word per line, what gen_soc_rom.init is).
 * Plain C, no libraries.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROM_WORDS    16384
#define W 160
#define H 128

static uint8_t* slurp(const char* path, size_t* n) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "mkrom: cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* b = malloc(len ? len : 1);
    if (fread(b, 1, len, f) != (size_t)len) { fprintf(stderr, "mkrom: cannot read %s\n", path); exit(1); }
    fclose(f);
    *n = len;
    return b;
}

static int ppm_int(const uint8_t* b, size_t n, size_t* p) {
    for (;;) {
        while (*p < n && (b[*p] == ' ' || b[*p] == '\n' || b[*p] == '\r' || b[*p] == '\t')) (*p)++;
        if (*p < n && b[*p] == '#') { while (*p < n && b[*p] != '\n') (*p)++; continue; }
        break;
    }
    int v = 0, digits = 0;
    while (*p < n && b[*p] >= '0' && b[*p] <= '9') { v = v * 10 + (b[*p] - '0'); (*p)++; digits++; }
    return digits ? v : -1;
}

/* the 40960-byte frame of the picture file */
static uint8_t* frame_of(const char* path) {
    size_t n;
    uint8_t* b = slurp(path, &n);
    uint8_t* fr = calloc(W * H, 2);
    if (n == (size_t)W * H * 2) { memcpy(fr, b, n); return fr; }
    if (n > 2 && b[0] == 'P' && b[1] == '6') {
        size_t p = 2;
        int w = ppm_int(b, n, &p), h = ppm_int(b, n, &p), mx = ppm_int(b, n, &p);
        if (w <= 0 || h <= 0 || mx != 255 || p >= n) { fprintf(stderr, "mkrom: %s: not a binary PPM with maxval 255\n", path); exit(1); }
        p++;                                              /* the single whitespace after maxval */
        if (n - p < (size_t)w * h * 3) { fprintf(stderr, "mkrom: %s: truncated PPM\n", path); exit(1); }
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                const uint8_t* px = b + p + ((size_t)(y * h / H) * w + (size_t)(x * w / W)) * 3;
                uint16_t c = (uint16_t)(((px[0] >> 3) << 11) | ((px[1] >> 2) << 5) | (px[2] >> 3));
                fr[(y * W + x) * 2] = c & 0xff;
                fr[(y * W + x) * 2 + 1] = c >> 8;
            }
        return fr;
    }
    fprintf(stderr, "mkrom: %s: %zu bytes is neither a %dx%d RGB565 frame (%d bytes) nor a binary PPM\n", path, n, W, H, W * H * 2);
    exit(1);
}


/* ---- photos: the frames of a romfs image ---- */
#define FLASH_ROOTFS 0x5C0000u        /* the rootfs partition in the SPI flash (linux/kernel/sonata-ram.dts) */

static uint32_t be32(const uint8_t* p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

struct photos { uint32_t off[256]; int n; };

/* walk the headers at `hdr` (a directory's entries), depth first; the romfs layout: next(4, low bits type), spec(4), size(4),
 * checksum(4), name padded to 16, data padded to 16 */
static void romfs_walk(const uint8_t* d, size_t len, uint32_t hdr, const char* path, const char* prefix, struct photos* ph, int depth) {
    while (hdr && hdr + 16 <= len && depth < 16) {
        uint32_t next = be32(d + hdr), spec = be32(d + hdr + 4), size = be32(d + hdr + 8);
        const char* nm = (const char*)d + hdr + 16;
        size_t nl = strnlen(nm, len - hdr - 16);
        uint32_t data = (uint32_t)((hdr + 16 + nl + 1 + 15) & ~15u);
        char full[1024];
        snprintf(full, sizeof full, "%s/%s", path, nm);
        int type = next & 7;
        if (type == 1 && strcmp(nm, ".") && strcmp(nm, "..")) romfs_walk(d, len, spec & ~15u, full, prefix, ph, depth + 1);
        else if (type == 2 && size == W * H * 2 && !strncmp(full, prefix, strlen(prefix)) && nl > 4 && !strcmp(nm + nl - 4, ".raw") &&
                 data + size <= len && ph->n < 256)
            ph->off[ph->n++] = FLASH_ROOTFS + data;
        hdr = next & ~15u;
    }
}

static int photos_main(const char* romfs, const char* out, const char* prefix) {
    struct photos ph = {{0}, 0};
    if (strcmp(romfs, "-")) {
        size_t n;
        uint8_t* d = slurp(romfs, &n);
        if (n < 32 || memcmp(d, "-rom1fs-", 8)) { fprintf(stderr, "mkrom: %s is not a romfs image\n", romfs); return 1; }
        uint32_t vol = (uint32_t)((16 + strnlen((const char*)d + 16, n - 16) + 1 + 15) & ~15u);
        romfs_walk(d, n, vol, "", prefix, &ph, 0);
    }
    FILE* f = fopen(out, "w");
    if (!f) { fprintf(stderr, "mkrom: cannot write %s\n", out); return 1; }
    fprintf(f, "# generated by mkrom photos %s: the flash offsets of %d frames (the rootfs is at 0x5C0000 in the flash)\n", romfs, ph.n);
    fprintf(f, "        .section .rodata, \"a\"\n        .balign 4\n        .globl  photo_count\nphoto_count:\n        .word   %d\n", ph.n);
    fprintf(f, "        .globl  photo_offset\nphoto_offset:\n");
    for (int i = 0; i < ph.n; i++) fprintf(f, "        .word   0x%x\n", ph.off[i]);
    if (!ph.n) fprintf(f, "        .word   0\n");
    if (fclose(f)) { fprintf(stderr, "mkrom: writing %s failed\n", out); return 1; }
    fprintf(stderr, "mkrom: %d frames\n", ph.n);
    return 0;
}

int main(int argc, char** argv) {
    if ((argc == 4 || argc == 5) && !strcmp(argv[1], "photos")) return photos_main(argv[2], argv[3], argc == 5 ? argv[4] : "/usr/share/photobox/");
    if (argc == 4 && !strcmp(argv[1], "frame")) {          /* mkrom frame PICTURE OUT.rgb565 */
        uint8_t* fr = frame_of(argv[2]);
        FILE* f = fopen(argv[3], "wb");
        if (!f || fwrite(fr, 1, W * H * 2, f) != (size_t)W * H * 2 || fclose(f)) { fprintf(stderr, "mkrom: cannot write %s\n", argv[3]); return 1; }
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "init")) {           /* mkrom init PROGRAM.bin OUT.init */
        size_t n;
        uint8_t* prog = slurp(argv[2], &n);
        if (n > (size_t)ROM_WORDS * 4) { fprintf(stderr, "mkrom: the program and picture are %zu bytes, the ROM holds %d\n", n, ROM_WORDS * 4); return 1; }
        uint8_t* rom = calloc(ROM_WORDS, 4);
        memcpy(rom, prog, n);
        FILE* f = fopen(argv[3], "w");
        if (!f) { fprintf(stderr, "mkrom: cannot write %s\n", argv[3]); return 1; }
        for (int k = 0; k < ROM_WORDS; k++) {
            uint32_t w = rom[4 * k] | rom[4 * k + 1] << 8 | rom[4 * k + 2] << 16 | (uint32_t)rom[4 * k + 3] << 24;
            fprintf(f, "%08x\n", w);
        }
        if (fclose(f)) { fprintf(stderr, "mkrom: writing %s failed\n", argv[3]); return 1; }
        return 0;
    }
    fprintf(stderr, "usage: mkrom photos ROMFS|- OUT.S [PREFIX]  the flash offsets of the frames in a romfs image\n       mkrom frame PICTURE OUT.rgb565   a 160x128 RGB565 frame from a raw frame or a binary PPM\n"
                    "       mkrom init PROGRAM.bin OUT.init  the $readmemh file of the 16384-word boot ROM\n");
    return 2;
}
