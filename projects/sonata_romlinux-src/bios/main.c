// This file is Copyright (c) 2013-2014 Sebastien Bourdeauducq <sb@m-labs.hk>
// This file is Copyright (c) 2014-2019 Florent Kermarrec <florent@enjoy-digital.fr>
// This file is Copyright (c) 2015 Yann Sionneau <ys@m-labs.hk>
// This file is Copyright (c) 2015 whitequark <whitequark@whitequark.org>
// This file is Copyright (c) 2019 Ambroz Bizjak <ambrop7@gmail.com>
// This file is Copyright (c) 2019 Caleb Jamison <cbjamo@gmail.com>
// This file is Copyright (c) 2018 Dolu1990 <charles.papon.90@gmail.com>
// This file is Copyright (c) 2018 Felix Held <felix-github@felixheld.de>
// This file is Copyright (c) 2019 Gabriel L. Somlo <gsomlo@gmail.com>
// This file is Copyright (c) 2018 Jean-François Nguyen <jf@lambdaconcept.fr>
// This file is Copyright (c) 2018 Sergiusz Bazanski <q3k@q3k.org>
// This file is Copyright (c) 2016 Tim 'mithro' Ansell <mithro@mithis.com>
// This file is Copyright (c) 2020 Franck Jullien <franck.jullien@gmail.com>
// This file is Copyright (c) 2020 Antmicro <www.antmicro.com>

// License: BSD

#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <system.h>
#include <irq.h>

#include "boot.h"
#include "readline.h"
#include "helpers.h"
#include "command.h"

#include <generated/csr.h>
#include <generated/soc.h>
#include <generated/mem.h>
#include <generated/git.h>

#include <libbase/console.h>
#include <libbase/crc.h>
#include <libbase/format.h>
#include <libbase/memtest.h>

#include <libbase/spiflash.h>
#include <libbase/uart.h>
#include <libbase/i2c.h>
#include <libbase/hyperram.h>

#include <liblitedram/sdram.h>
#include <liblitedram/utils.h>

#include <libliteeth/udp.h>
#include <libliteeth/mdio.h>

#include <liblitespi/spiflash.h>
#include <liblitespi/spiram.h>

#include <liblitesdcard/sdcard.h>
#include <liblitesata/sata.h>

#ifndef CONFIG_BIOS_NO_BOOT
#define BOOT_METHOD_CONTINUE 1
#define BOOT_METHOD_STOP     0

#if defined(CSR_UART_BASE) && !defined(SERIAL_BOOT_DISABLE)
#ifndef SERIAL_BOOT_PRIORITY
#define SERIAL_BOOT_PRIORITY 0
#endif
static int serial_boot_method(void)
{
	return serialboot();
}
define_boot_method(serial, serial_boot_method, SERIAL_BOOT_PRIORITY);
#endif

#if defined(FLASH_BOOT_ADDRESS) && !defined(FLASH_BOOT_DISABLE)
#ifndef FLASH_BOOT_PRIORITY
#define FLASH_BOOT_PRIORITY 10
#endif
static int flash_boot_method(void)
{
	flashboot();
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(flash, flash_boot_method, FLASH_BOOT_PRIORITY);
#endif

#if defined(ROM_BOOT_ADDRESS) && !defined(ROM_BOOT_DISABLE)
#ifndef ROM_BOOT_PRIORITY
#define ROM_BOOT_PRIORITY 20
#endif
static int rom_boot_method(void)
{
	romboot();
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(rom, rom_boot_method, ROM_BOOT_PRIORITY);
#endif

#ifdef LCD_BASE
/* Status lines on the LCD text console (rtl/lcd_text.v): 20 columns, row 0 is the white title, 1..15 text. */
static void lcd_line(unsigned int row, const char *text)
{
	volatile uint8_t *p = (volatile uint8_t *)(LCD_BASE + row * 20);
	unsigned int c;

	for (c = 0; c < 20; c++)
		p[c] = *text ? *text++ : ' ';
}
static void lcd_clear(void)
{
	unsigned int r;

	*(volatile uint32_t *)(LCD_BASE + 0x140) = 0;	/* scroll register */
	for (r = 0; r < 16; r++)
		lcd_line(r, "");
}
#else
#define lcd_line(row, text) do { } while (0)
#define lcd_clear() do { } while (0)
#endif

#if !defined(KERNELBOOT_DISABLE)
/* Standalone boot, no network: the kernel image (the 4 KB M-mode stub followed by the RAM kernel Image, i.e.
   what tftpboot downloads) is kept in flash at 0x02000000. Copy it to RAM at 0x40200000 and enter it exactly
   as tftpboot does. Press Q or ESC at the boot countdown to get the prompt (and tftpboot) instead. */
#ifndef KERNELBOOT_PRIORITY
#define KERNELBOOT_PRIORITY 30
#endif
#define KERNEL_FLASH      0x02000000UL
#define KERNEL_RAM        0x40200000UL
#define KERNEL_MAX_SIZE   0x500000UL     /* copied unconditionally, the flash kernel_a partition is 0x540000 */
#define KERNEL_IMAGE_OFF  0x1000UL       /* the stub is 4 KB */
#define RISCV_IMAGE_MAGIC 0x05435352UL   /* "RSC\x05" at offset 0x38 of the Image header */
static int kernel_boot_method(void)
{
	volatile uint32_t *src = (volatile uint32_t *)KERNEL_FLASH;
	volatile uint32_t *dst = (volatile uint32_t *)KERNEL_RAM;
	uint32_t i;

	lcd_clear();
	lcd_line(0, "SONATA BIOS");
	if (src[0] == 0xffffffff || src[(KERNEL_IMAGE_OFF + 0x38) / 4] != RISCV_IMAGE_MAGIC) {
		printf("Kernel boot: no kernel image in flash, skipping\n");
		lcd_line(1, "NO KERNEL IN FLASH");
		return BOOT_METHOD_CONTINUE;
	}
	lcd_line(1, "KERNEL IN FLASH");
	lcd_line(2, "COPYING TO RAM...");
	printf("Kernel boot: copying %lu KiB from flash 0x%08lx to 0x%08lx\n",
		KERNEL_MAX_SIZE / 1024, KERNEL_FLASH, KERNEL_RAM);
	for (i = 0; i < KERNEL_MAX_SIZE / 4; i++)
		dst[i] = src[i];
	lcd_line(3, "STARTING LINUX");
	boot(0, 0, 0, KERNEL_RAM);
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(kernel, kernel_boot_method, KERNELBOOT_PRIORITY);
#endif

#if defined(SPIETH_BASE) && !defined(SPIETH_BOOT_DISABLE)
#ifndef SPIETH_BOOT_PRIORITY
#define SPIETH_BOOT_PRIORITY 40
#endif
static int spieth_boot_method(void)
{
	spieth_tftp_boot();   /* boots and does not return, or gives up */
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(spieth, spieth_boot_method, SPIETH_BOOT_PRIORITY);
#endif

#if (defined(CSR_SPISDCARD_BASE) || defined(CSR_SDCARD_BASE)) && !defined(SDCARD_BOOT_DISABLE)
#ifndef SDCARD_BOOT_PRIORITY
#define SDCARD_BOOT_PRIORITY 30
#endif
static int sdcard_boot_method(void)
{
	sdcardboot(0, NULL);
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(sdcard, sdcard_boot_method, SDCARD_BOOT_PRIORITY);
#endif

#if defined(CSR_SATA_SECTOR2MEM_BASE) && !defined(SATA_BOOT_DISABLE)
#ifndef SATA_BOOT_PRIORITY
#define SATA_BOOT_PRIORITY 40
#endif
static int sata_boot_method(void)
{
	sataboot(0, NULL);
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(sata, sata_boot_method, SATA_BOOT_PRIORITY);
#endif

#if defined(CSR_ETHMAC_BASE) && !defined(NET_BOOT_DISABLE)
#ifndef NET_BOOT_PRIORITY
/* Network boot goes FIRST (lowest value runs first; serial is 0): with a
 * TFTP server up the board boots unattended, and every other method is still
 * tried if the netboot fails.  At the old 50 it came last, behind an SD boot
 * that on a board whose card does not answer stalls in timeouts and never
 * reaches the network without a hand at the console.  Build with
 * -DNET_BOOT_PRIORITY=50 (or a SoC constant) for the old order. */
#define NET_BOOT_PRIORITY -10
#endif
static int net_boot_method(void)
{
#ifdef CSR_ETHPHY_MODE_DETECTION_MODE_ADDR
	eth_mode();
#endif
#ifdef ETH_WITH_DHCP
	dhcp_get_ip();
#endif
	netboot(0, NULL);
	return BOOT_METHOD_CONTINUE;
}
define_boot_method(net, net_boot_method, NET_BOOT_PRIORITY);
#endif

static void boot_sequence(void)
{
	const struct boot_method *const *boot_method;
	int priority;

	priority = INT_MIN;
	while (1) {
		int next_priority;
		int found;

		next_priority = INT_MAX;
		found = 0;
		for (boot_method = __bios_boot_start; boot_method != __bios_boot_end; boot_method++) {
			if ((*boot_method)->priority <= priority)
				continue;
			if (found && ((*boot_method)->priority >= next_priority))
				continue;
			next_priority = (*boot_method)->priority;
			found = 1;
		}
		if (!found)
			break;

		for (boot_method = __bios_boot_start; boot_method != __bios_boot_end; boot_method++) {
			if ((*boot_method)->priority != next_priority)
				continue;
			if ((*boot_method)->handler() == BOOT_METHOD_STOP)
				return;
		}

		priority = next_priority;
	}

	printf("No boot medium found\n");
}
#endif

__attribute__((__used__)) int main(int i, char **c)
{
#ifndef BIOS_CONSOLE_DISABLE
	char buffer[CMD_LINE_BUFFER_SIZE];
	char *params[MAX_PARAM];
	char *command;
	struct command_struct *cmd;
	int nb_params;
#endif
	int sdr_ok;

#ifdef CONFIG_CPU_HAS_INTERRUPT
	irq_setmask(0);
	irq_setie(1);
#endif
#ifdef CSR_UART_BASE
	uart_init();
#endif

#ifdef CONFIG_HAS_I2C
	i2c_send_init_cmds();
#endif

#ifndef CONFIG_BIOS_NO_PROMPT
	printf("\n");
	printf(ANSI_BOLD "        __   _ __      _  __" ANSI_RESET "\n");
	printf(ANSI_BOLD "       / /  (_) /____ | |/_/" ANSI_RESET "\n");
	printf(ANSI_BOLD "      / /__/ / __/ -_)>  <" ANSI_RESET "\n");
	printf(ANSI_BOLD "     /____/_/\\__/\\__/_/|_|" ANSI_RESET "\n");
#ifdef CONFIG_BIOS_BANNER_TAGLINE
	printf(ANSI_BOLD "   " CONFIG_BIOS_BANNER_TAGLINE ANSI_RESET "\n");
#else
	printf(ANSI_BOLD "   Build your hardware, easily!" ANSI_RESET "\n");
#endif
	printf("\n");
	printf(" (c) Copyright 2012-2026 Enjoy-Digital\n");
	printf(" (c) Copyright 2007-2015 M-Labs\n");
	printf("\n");
#ifndef CONFIG_BIOS_NO_BUILD_TIME
	printf(" BIOS built on "__DATE__" "__TIME__"\n");
#endif
#ifndef CONFIG_BIOS_NO_CRC
	crcbios();
#endif
	printf("\n");
	printf(" LiteX git sha1: "LITEX_GIT_SHA1"\n");
	printf("\n");
	bios_print_section("SoC");
	printf(ANSI_BOLD "CPU" ANSI_RESET ":\t\t%s @ %dMHz\n",
		CONFIG_CPU_HUMAN_NAME,
#ifdef CONFIG_CPU_CLK_FREQ
		CONFIG_CPU_CLK_FREQ/1000000);
#else
		CONFIG_CLOCK_FREQUENCY/1000000);
#endif
	printf(ANSI_BOLD "BUS" ANSI_RESET ":\t\t%s %d-bit data/%d-bit addr\n",
		CONFIG_BUS_STANDARD,
		CONFIG_BUS_DATA_WIDTH,
		CONFIG_BUS_ADDRESS_WIDTH);
	printf(ANSI_BOLD "CSR" ANSI_RESET ":\t\t%d-bit data ",
		CONFIG_CSR_DATA_WIDTH);
#ifdef CONFIG_CSR_ORDERING_BIG
	printf("big ordering\n");
#else
	printf("little ordering\n");
#endif
	printf(ANSI_BOLD "ROM" ANSI_RESET ":\t\t");
	litex_print_size(ROM_SIZE);
	printf("\n");
	printf(ANSI_BOLD "SRAM" ANSI_RESET ":\t\t");
	litex_print_size(SRAM_SIZE);
	printf("\n");
#ifdef CONFIG_L2_SIZE
	printf(ANSI_BOLD "L2" ANSI_RESET ":\t\t");
	litex_print_size(CONFIG_L2_SIZE);
	printf("\n");
#endif
#ifdef SPIFLASH_MODULE_TOTAL_SIZE
	printf(ANSI_BOLD "FLASH" ANSI_RESET ":\t\t");
	litex_print_size(SPIFLASH_MODULE_TOTAL_SIZE);
	printf("\n");
#endif
#ifdef MAIN_RAM_SIZE
#ifdef CSR_SDRAM_BASE
	uint64_t supported_memory = sdram_get_supported_memory();
	printf(ANSI_BOLD "SDRAM" ANSI_RESET ":\t\t");
	litex_print_size(supported_memory);
	printf(" %d-bit @ %dMT/s ",
		sdram_get_databits(),
		sdram_get_freq()/1000000);
	printf("(CL-%d",
		sdram_get_cl());
	if (sdram_get_cwl() != -1)
		printf(" CWL-%d", sdram_get_cwl());
	printf(")\n");
#endif
	printf(ANSI_BOLD "MAIN RAM" ANSI_RESET ":\t");
	litex_print_size(MAIN_RAM_SIZE);
	printf("\n");
#endif
	printf("\n");
#endif

	sdr_ok = 1;

#ifdef CSR_HYPERRAM_BASE
	hyperram_init();
#endif

#if defined(CSR_ETHMAC_BASE) || defined(MAIN_RAM_BASE_VA) || defined(CSR_SPIFLASH_BASE)
	bios_print_section("Initialization");
#ifdef CSR_ETHMAC_BASE
	eth_init();
	net_init();
	set_idle_hook(udp_service);
#endif

	/* Initialize and test SPIRAM */
#ifdef CSR_SPIRAM_BASE
	spiram_init();
	printf("\n");
#endif

	/* Initialize and test DRAM */
#ifdef CSR_SDRAM_BASE
	sdr_ok = sdram_init();
#else
	/* Test Main RAM when present and not pre-initialized */
#ifdef MAIN_RAM_BASE_VA
#ifndef CONFIG_MAIN_RAM_INIT
	sdr_ok = memtest((unsigned int *) MAIN_RAM_BASE_VA, min(MAIN_RAM_SIZE, MEMTEST_DATA_SIZE));
	memspeed((unsigned int *) MAIN_RAM_BASE_VA, min(MAIN_RAM_SIZE, MEMTEST_DATA_SIZE), false, 0);
#endif
#endif
#endif
	if (sdr_ok != 1)
		printf("Memory initialization failed\n");
#endif

	/* Initialize and test SPIFLASH */
#ifdef CSR_SPIFLASH_BASE
	spiflash_init();
	printf("\n");
#endif

	/* Initialize Video Framebuffer FIXME: Move */
#ifdef CSR_VIDEO_FRAMEBUFFER_BASE
	video_framebuffer_vtg_enable_write(0);
	video_framebuffer_dma_enable_write(0);
	video_framebuffer_vtg_enable_write(1);
	video_framebuffer_dma_enable_write(1);
#endif

	/* Execute  initialization functions */
	init_dispatcher();

	/* Execute Boot sequence */
#ifndef CONFIG_BIOS_NO_BOOT
	if(sdr_ok) {
		bios_print_section("Boot");
		boot_sequence();
		printf("\n");
	}
#endif

	/* Console */
#ifdef BIOS_CONSOLE_DISABLE
	bios_print_section("Done (No Console)");
#else
	bios_print_section("Console");
#if !defined(BIOS_CONSOLE_LITE) && !defined(BIOS_CONSOLE_NO_HISTORY)
	hist_init();
#endif
	printf("\n%s", PROMPT);
	while(1) {
		readline(buffer, CMD_LINE_BUFFER_SIZE);
		printf("\n");
		if (buffer[0] != 0) {
			nb_params = get_param(buffer, &command, params);
			/* Ignore whitespace-only lines */
			if (*command != 0) {
				cmd = command_dispatcher(command, nb_params, params);
				if (!cmd)
					printf("Command not found\n");
			}
		}
		printf("%s", PROMPT);
	}
#endif
	return 0;
}
