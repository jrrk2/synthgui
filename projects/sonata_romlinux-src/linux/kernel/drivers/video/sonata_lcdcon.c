// SPDX-License-Identifier: GPL-2.0
/*
 * Kernel message console on the Sonata board's 160x128 LCD (the "lcd_text" gateware block: 20 x 16 characters).
 *
 * Row 0 is a title bar with the uptime; rows 1..15 show the last 15 kernel messages, scrolled by the block's
 * hardware scroll register.  A message's "[ time ]" prefix is dropped and text that does not fit in 20 columns is
 * truncated, so the screen shows at a glance what the kernel is doing.
 *
 * Register window (write only): byte row*20+col is a character (bit 7 selects yellow), word 80 (byte 0x140) is the
 * scroll register 0..14.
 */
#include <linux/console.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/printk.h>
#include <linux/timer.h>

#define COLS		20
#define TEXT_ROWS	15		/* rows 1..15; row 0 is the title */
#define SCROLL_REG	0x140

static void __iomem *lcd;
static unsigned int cur_row;		/* displayed text row 0..14 */
static unsigned int cur_col;
static unsigned int top;		/* hardware scroll value */
static bool at_line_start = true;
static bool in_prefix;
static struct timer_list title_timer;

static inline unsigned int ram_row(unsigned int disp_row)
{
	return 1 + (disp_row + top) % TEXT_ROWS;
}

static void put_char(unsigned int ramrow, unsigned int col, u8 ch)
{
	writeb(ch, lcd + ramrow * COLS + col);
}

static void clear_row(unsigned int ramrow)
{
	unsigned int c;

	for (c = 0; c < COLS; c++)
		put_char(ramrow, c, ' ');
}

static void newline(void)
{
	cur_col = 0;
	at_line_start = true;
	if (cur_row < TEXT_ROWS - 1) {
		cur_row++;
		clear_row(ram_row(cur_row));
		return;
	}
	/* scroll: the oldest line becomes the new, blank, bottom line */
	clear_row(ram_row(0));
	top = (top + 1) % TEXT_ROWS;
	writel(top, lcd + SCROLL_REG);
}

static void lcdcon_write(struct console *con, const char *s, unsigned int n)
{
	while (n--) {
		char ch = *s++;

		if (at_line_start && ch == '[') {		/* "[ 12.345678] " */
			in_prefix = true;
			at_line_start = false;
			continue;
		}
		if (in_prefix) {
			if (ch == ']')
				in_prefix = false;
			continue;
		}
		at_line_start = false;
		if (ch == '\n') {
			newline();
		} else if (ch == '\r') {
			cur_col = 0;
		} else if (ch >= ' ' && ch < 0x7f) {
			if (cur_col == 0 && ch == ' ')		/* the space after the prefix */
				continue;
			if (cur_col < COLS)			/* truncate */
				put_char(ram_row(cur_row), cur_col, ch);
			cur_col++;
		}
	}
}

static struct console lcdcon = {
	.name	= "lcdcon",
	.write	= lcdcon_write,
	.flags	= CON_PRINTBUFFER | CON_ENABLED,
	.index	= -1,
};

static void put_title(const char *s)
{
	unsigned int c;

	for (c = 0; c < COLS; c++)
		put_char(0, c, *s ? *s++ : ' ');
}

static void title_tick(struct timer_list *t)
{
	char buf[COLS + 1];
	unsigned long up = jiffies_to_msecs(jiffies) / 1000;

	snprintf(buf, sizeof(buf), "SONATA LINUX %5lus", up);
	put_title(buf);
	mod_timer(&title_timer, jiffies + HZ);
}

static int __init sonata_lcdcon_init(void)
{
	struct device_node *np = of_find_compatible_node(NULL, NULL, "sonata,lcdtext");
	unsigned int r;

	if (!np)
		return -ENODEV;
	lcd = of_iomap(np, 0);
	of_node_put(np);
	if (!lcd)
		return -ENOMEM;

	for (r = 1; r <= TEXT_ROWS; r++)
		clear_row(r);
	writel(0, lcd + SCROLL_REG);
	put_title("SONATA LINUX");
	cur_row = 0;
	cur_col = 0;
	top = 0;
	at_line_start = true;
	register_console(&lcdcon);
	timer_setup(&title_timer, title_tick, 0);
	mod_timer(&title_timer, jiffies + HZ);
	return 0;
}
console_initcall(sonata_lcdcon_init);
