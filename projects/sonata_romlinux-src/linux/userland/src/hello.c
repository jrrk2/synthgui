/* hello.c -- text, lines and shapes on the LCD.   build.sh # or: tcc -static hello.c -o /tmp/hello && /tmp/hello */
#include "gfx.h"

int main(void)
{
    if (gfx_open())
        return 1;
    gfx_clear(rgb(0, 0, 40));
    gfx_text(8, 8, "Hello,", rgb(255, 255, 255), 2);
    gfx_text(8, 28, "Sonata!", rgb(255, 220, 0), 3);
    for (int i = 0; i < 8; i++)
        gfx_rect(8 + i * 4, 62 + i * 3, 60 - i * 8, 40 - i * 4, rgb(32 * i, 255 - 32 * i, 128), 0);
    gfx_circle(120, 85, 28, rgb(0, 255, 120));
    gfx_circle(120, 85, 18, rgb(255, 80, 80));
    gfx_line(0, 127, 159, 60, rgb(120, 160, 255));
    gfx_text(4, 116, "tcc on board", rgb(180, 180, 180), 1);
    gfx_flip();
    sleep(10);          /* the panel shows the frame buffer while the device is open */
    gfx_close();
    return 0;
}
