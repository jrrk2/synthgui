/* plasma.c -- animated plasma (integer maths only).   tcc -static plasma.c -o /tmp/plasma && /tmp/plasma [frames] */
#include "gfx.h"

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 200;
    uint16_t pal[256];
    if (gfx_open())
        return 1;
    for (int i = 0; i < 256; i++)
        pal[i] = rgb(128 + gfx_sin(i) , 128 + gfx_sin(i + 85), 128 + gfx_sin(i + 170));
    for (int t = 0; t < frames; t++) {
        for (int y = 0; y < GFX_H; y++)
            for (int x = 0; x < GFX_W; x++) {
                int v = gfx_sin(x * 3 + t * 2) + gfx_sin(y * 4 - t * 3) + gfx_sin((x + y) * 2 + t);
                gfx_buf[y * GFX_W + x] = pal[(v / 2 + 128) & 255];
            }
        gfx_flip();
    }
    gfx_close();
    return 0;
}
