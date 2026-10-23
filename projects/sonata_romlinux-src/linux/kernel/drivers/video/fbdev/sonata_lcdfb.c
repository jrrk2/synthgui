// SPDX-License-Identifier: GPL-2.0
/*
 * Frame buffer for the Sonata board's 160x128 ST7735 LCD ("lcd_text" gateware block).
 *
 * /dev/fb0 is 160x128, 16 bpp, RGB565 (the gateware swaps red and blue for the panel's BGR order). The pixels
 * live in a write-only window: reading them back returns zeros, so only writing, mmap-ing and writing through
 * write(2) are useful.  While the device is open the panel shows the frame buffer instead of the text console
 * (see sonata_lcdcon.c); the text console comes back when the last user closes it.
 *
 * Device tree: compatible "sonata,lcdfb", reg = <frame buffer window>, <text/console window>; the mode
 * register is word 81 (byte 0x144) of the second window.
 */
#include <linux/fb.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>

#define LCD_W		160
#define LCD_H		128
#define MODE_REG	0x144

struct sonata_fb {
	void __iomem *mode;
	unsigned int users;
	struct mutex lock;
};

static int sonata_fb_open(struct fb_info *info, int user)
{
	struct sonata_fb *par = info->par;

	if (!user)
		return 0;
	mutex_lock(&par->lock);
	if (par->users++ == 0)
		writel(1, par->mode);
	mutex_unlock(&par->lock);
	return 0;
}

static int sonata_fb_release(struct fb_info *info, int user)
{
	struct sonata_fb *par = info->par;

	if (!user)
		return 0;
	mutex_lock(&par->lock);
	if (--par->users == 0)
		writel(0, par->mode);
	mutex_unlock(&par->lock);
	return 0;
}

static const struct fb_ops sonata_fb_ops = {
	.owner		= THIS_MODULE,
	.fb_open	= sonata_fb_open,
	.fb_release	= sonata_fb_release,
	FB_DEFAULT_IOMEM_OPS,
};

static int sonata_fb_probe(struct platform_device *pdev)
{
	struct resource *fbres, *ctlres;
	struct fb_info *info;
	struct sonata_fb *par;
	void __iomem *ctl;
	int ret;

	fbres = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	ctlres = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!fbres || !ctlres)
		return -ENODEV;
	ctl = devm_ioremap(&pdev->dev, ctlres->start, resource_size(ctlres));
	if (!ctl)
		return -ENOMEM;

	info = framebuffer_alloc(sizeof(*par), &pdev->dev);
	if (!info)
		return -ENOMEM;
	par = info->par;
	par->mode = ctl + MODE_REG;
	mutex_init(&par->lock);

	info->screen_base = devm_ioremap(&pdev->dev, fbres->start, LCD_W * LCD_H * 2);
	if (!info->screen_base) {
		ret = -ENOMEM;
		goto err;
	}
	info->fbops = &sonata_fb_ops;
	strscpy(info->fix.id, "sonata-lcd", sizeof(info->fix.id));
	info->fix.type = FB_TYPE_PACKED_PIXELS;
	info->fix.visual = FB_VISUAL_TRUECOLOR;
	info->fix.smem_start = fbres->start;
	info->fix.smem_len = LCD_W * LCD_H * 2;
	info->fix.line_length = LCD_W * 2;
	info->var.xres = info->var.xres_virtual = LCD_W;
	info->var.yres = info->var.yres_virtual = LCD_H;
	info->var.bits_per_pixel = 16;
	info->var.red = (struct fb_bitfield){ .offset = 11, .length = 5 };
	info->var.green = (struct fb_bitfield){ .offset = 5, .length = 6 };
	info->var.blue = (struct fb_bitfield){ .offset = 0, .length = 5 };
	info->var.activate = FB_ACTIVATE_NOW;
	info->var.height = 25;		/* mm, roughly */
	info->var.width = 32;

	ret = register_framebuffer(info);
	if (ret)
		goto err;
	platform_set_drvdata(pdev, info);
	dev_info(&pdev->dev, "%dx%d RGB565 frame buffer, /dev/fb%d\n", LCD_W, LCD_H, info->node);
	return 0;
err:
	framebuffer_release(info);
	return ret;
}

static const struct of_device_id sonata_fb_of_match[] = {
	{ .compatible = "sonata,lcdfb" },
	{ }
};

static struct platform_driver sonata_fb_driver = {
	.probe	= sonata_fb_probe,
	.driver	= {
		.name		= "sonata-lcdfb",
		.of_match_table	= sonata_fb_of_match,
	},
};
builtin_platform_driver(sonata_fb_driver);
