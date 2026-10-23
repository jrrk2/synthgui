/* mandel.c -- Mandelbrot set in 16.16 fixed point, bright palette, drawn a band at a time.
 * build.sh # or: tcc -static mandel.c -o /tmp/mandel && /tmp/mandel [max_iterations]            */
#include "gfx.h"

int main(int argc, char **argv)
{
    int maxit = argc > 1 ? atoi(argv[1]) : 48;
    uint16_t pal[64];
    if (gfx_open())
        return 1;
    for (int i = 0; i < 64; i++)
        pal[i] = rgb(255 * (gfx_sin(i * 4 + 64) + 127) / 254, 255 * (gfx_sin(i * 4 + 128 + 64) + 127) / 254,
                     255 * (gfx_sin(i * 4 + 192 + 64) + 127) / 254);
    gfx_clear(0);
    /* the view: x from -2.2 to 1.0, y from -1.2 to 1.2 */
    for (int py = 0; py < GFX_H; py++) {
        int cy = -78643 + py * 1228;                 /* -1.2 + py * 2.4/128 in 16.16 */
        for (int px = 0; px < GFX_W; px++) {
            int cx = -144179 + px * 1311;            /* -2.2 + px * 3.2/160 */
            int x = 0, y = 0, it = 0;
            while (it < maxit) {
                int x2 = (int)(((long long)x * x) >> 16), y2 = (int)(((long long)y * y) >> 16);
                if (x2 + y2 > 4 << 16)
                    break;
                y = (int)(((long long)x * y) >> 15) + cy;
                x = x2 - y2 + cx;
                it++;
            }
            gfx_buf[py * GFX_W + px] = it == maxit ? 0 : pal[it & 63];
        }
        if ((py & 7) == 7)
            gfx_flip();
    }
    sleep(15);
    gfx_close();
    return 0;
}
