/* life.c -- Conway's Game of Life on a 160x128 torus.   tcc -static life.c -o /tmp/life && /tmp/life [generations] */
#include "gfx.h"

static uint8_t cur[GFX_H][GFX_W], nxt[GFX_H][GFX_W];

int main(int argc, char **argv)
{
    int gens = argc > 1 ? atoi(argv[1]) : 300;
    unsigned seed = 12345;
    if (gfx_open())
        return 1;
    for (int y = 0; y < GFX_H; y++)
        for (int x = 0; x < GFX_W; x++) {
            seed = seed * 1103515245 + 12345;
            cur[y][x] = (seed >> 16) % 4 == 0;
        }
    for (int g = 0; g < gens; g++) {
        for (int y = 0; y < GFX_H; y++)
            for (int x = 0; x < GFX_W; x++) {
                int n = 0;
                for (int dy = -1; dy <= 1; dy++)
                    for (int dx = -1; dx <= 1; dx++)
                        if (dx || dy)
                            n += cur[(y + dy + GFX_H) % GFX_H][(x + dx + GFX_W) % GFX_W];
                nxt[y][x] = n == 3 || (n == 2 && cur[y][x]);
                gfx_buf[y * GFX_W + x] = nxt[y][x] ? rgb(80 + (x * 175) / GFX_W, 255, 80 + (y * 175) / GFX_H) : rgb(0, 0, 24);
            }
        memcpy(cur, nxt, sizeof(cur));
        gfx_flip();
    }
    gfx_close();
    return 0;
}
