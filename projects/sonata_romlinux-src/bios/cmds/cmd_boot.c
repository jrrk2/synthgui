// SPDX-License-Identifier: BSD-Source-Code

#include <stdio.h>
#include <stdlib.h>

#include <generated/csr.h>
#include <generated/soc.h>

#include "../command.h"
#include "../helpers.h"
#include "../boot.h"

/**
 * Command "boot"
 *
 * Boot software from system memory
 *
 */

static void boot_handler(int nb_params, char **params)
{
	char *c;
	unsigned long addr;
	unsigned long r1;
	unsigned long r2;
	unsigned long r3;

	if (nb_params < 1) {
		printf("boot <address> [r1] [r2] [r3]\n");
		return;
	}
	addr = strtoul(params[0], &c, 0);
	if (*c != 0) {
		printf("Error: invalid address\n");
		return;
	}
	r1 = 0;
	if (nb_params > 1) {
		r1 = strtoul(params[1], &c, 0);
		if (*c != 0) {
			printf("Error: invalid r1\n");
			return;
		}
	}
	r2 = 0;
	if (nb_params > 2) {
		r2 = strtoul(params[2], &c, 0);
		if (*c != 0) {
			printf("Error: invalid r2\n");
			return;
		}
	}
	r3 = 0;
	if (nb_params > 3) {
		r3 = strtoul(params[3], &c, 0);
		if (*c != 0) {
			printf("Error: invalid r3\n");
			return;
		}
	}
	boot(r1, r2, r3, addr);
}
define_command(boot, boot_handler, "Boot from Memory",  BOOT_CMDS);

/**
 * Command "reboot"
 *
 * Reboot the system
 *
 */
#ifdef CSR_CTRL_RESET_ADDR
static void reboot_handler(int nb_params, char **params)
{
	ctrl_reset_write(1);
}

define_command(reboot, reboot_handler, "Reboot",  BOOT_CMDS);
#endif

/**
 * Command "flashboot"
 *
 * Boot software from flash
 *
 */
#ifdef FLASH_BOOT_ADDRESS
define_command(flashboot, flashboot, "Boot from Flash", BOOT_CMDS);
#endif

/**
 * Command "romboot"
 *
 * Boot software from embedded rom
 *
 */
#ifdef ROM_BOOT_ADDRESS
define_command(romboot, romboot, "Boot from ROM", BOOT_CMDS);
#endif

/**
 * Command "serialboot"
 *
 * Boot software from serial interface
 *
 */
#ifdef CSR_UART_BASE
define_command(serialboot, serialboot, "Boot from Serial (SFL)", BOOT_CMDS);
#endif

/**
 * Command "netboot"
 *
 * Boot software from TFTP server
 *
 */
#ifdef CSR_ETHMAC_BASE
define_command(netboot, netboot, "Boot via Ethernet (TFTP)", BOOT_CMDS);
#endif

/**
 * Command "spisdcardboot"
 *
 * Boot software from SDCard
 *
 */
#if defined(CSR_SPISDCARD_BASE) || defined(CSR_SDCARD_BASE)
define_command(sdcardboot, sdcardboot, "Boot from SDCard", BOOT_CMDS);
#endif

/**
 * Command "tftpboot"
 *
 * Boot software over the KSZ8851 SPI Ethernet (DHCP, then TFTP)
 *
 */
#if defined(SPIETH_BASE)
static void tftpboot_handler(int nb_params, char **params)
{
	spieth_tftp_boot();
	printf("TFTP boot failed\n");
}
define_command(tftpboot, tftpboot_handler, "Boot via SPI Ethernet (DHCP+TFTP)", BOOT_CMDS);

static void tftpget_handler(int nb_params, char **params)
{
	char *c;
	unsigned long addr;
	if (nb_params < 2) {
		printf("tftpget <file> <addr>\n");
		return;
	}
	addr = strtoul(params[1], &c, 0);
	if (*c != 0) {
		printf("Incorrect address\n");
		return;
	}
	spieth_tftp_get(params[0], addr);
}
define_command(tftpget, tftpget_handler, "Fetch a file via SPI Ethernet TFTP into RAM", BOOT_CMDS);

#if defined(CSR_SPIFLASH_MASTER_CS_ADDR)
static void tftpflash_handler(int nb_params, char **params)
{
	char *c;
	unsigned long off;
	if (nb_params < 2) {
		printf("tftpflash <file> <flash offset, multiple of 0x10000>\n");
		return;
	}
	off = strtoul(params[1], &c, 0);
	if (*c != 0 || (off & 0xffff) || off >= 0x1000000) {
		printf("Incorrect flash offset (a multiple of 0x10000 below 0x1000000)\n");
		return;
	}
	spieth_tftp_flash(params[0], off);
}
define_command(tftpflash, tftpflash_handler, "Stream a TFTP file into the flash (erase, write, verify)", BOOT_CMDS);
#endif
#endif

/**
 * Command "sataboot"
 *
 * Boot software from SATA
 *
 */
#if defined(CSR_SATA_SECTOR2MEM_BASE)
define_command(sataboot, sataboot, "Boot from SATA", BOOT_CMDS);
#endif
