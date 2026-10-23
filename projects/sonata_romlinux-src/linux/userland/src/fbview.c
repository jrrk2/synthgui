/* fbview.c -- show a raw 160x128 RGB565 image (40960 bytes; a gzip copy works with zcat) from a file or stdin.
 * build.sh # or: tcc -static fbview.c -o /tmp/fbview && /tmp/fbview image.raw [seconds]
 * wget -q -O - http://host/image.raw | /tmp/fbview - 10                                                    */
#include "gfx.h"

int main(int argc, char **argv)
{
    int secs = argc > 2 ? atoi(argv[2]) : 10;
    FILE *f = (argc < 2 || !strcmp(argv[1], "-")) ? stdin : fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    size_t n = fread(gfx_buf, 1, sizeof(gfx_buf), f);
    if (n != sizeof(gfx_buf)) {
        fprintf(stderr, "fbview: got %u bytes, a frame is %u (160x128 RGB565)\n", (unsigned)n, (unsigned)sizeof(gfx_buf));
        return 1;
    }
    if (gfx_open())
        return 1;
    gfx_flip();
    sleep(secs);
    gfx_close();
    return 0;
}
