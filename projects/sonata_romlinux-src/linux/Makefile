# Builds the Linux side of sonata_romlinux: the files in images/ are built with this Makefile.
#
#   images/stub.bin        4 KB M-mode stub (stub.S, GPL-compatible source in this directory)
#   images/kernel.bin      stub.bin + the RAM kernel Image; what the BIOS boots from flash or over TFTP
#   images/sonata-ram.dtb  the device tree built into the kernel (kernel/sonata-ram.dts)
#   images/rootfs.romfs    the read-only root filesystem (romfs) for the flash `rootfs` partition: BusyBox 1.37.0 +
#                          musl 1.2.5 built here (userland/), the other programs from rootfs-base.romfs
#
# Kernel source: https://github.com/jrrk2/linux revision af93851f1ec4d62f7f8c91b5399849c604c19144, built from
# tinyconfig + kernel/ram-additions.config. kernel/drivers/ replaces the same-named files in that tree (Sonata
# patches to spi-opentitan and the KSZ8851 driver); kernel/sonata-ram.dts is the built-in DTB.
#
# Tools: riscv64-elf-gcc with an rv32 multilib, dtc, GNU make, bison, flex, python3.
# On macOS also: GNU coreutils/sed/findutils/grep in PATH (gnubin), ld.lld (brew install lld), and the host
# header shims in kernel/hostinc (elf.h, byteswap.h; the kernel's host tools expect Linux headers).
#
#   make            build everything into images/
#   make flash      print the BIOS commands that write the images to the board's flash
#
# Flash layout (the soldered 32 MB W25Q256, mapped at 0x02000000):
#   0x000000  kernel.bin   (kernel_a partition, 0x540000)
#   0x5C0000  rootfs.romfs (rootfs partition)

CROSS      ?= riscv64-elf-
KERNEL_REV ?= af93851f1ec4d62f7f8c91b5399849c604c19144
KERNEL_URL ?= https://github.com/jrrk2/linux.git
LINUX      ?= $(CURDIR)/build/linux
# rootfs-base.romfs: the romfs from sonata-linux (genromfs of the buildroot target); no /sbin/init in it
ROOTFS_BASE ?= $(CURDIR)/rootfs-base.romfs
JOBS       ?= 8
MUSL_VER   ?= 1.2.5
BUSYBOX_VER ?= 1.37.0
SYSROOT    := $(CURDIR)/build/sysroot
BB         := $(CURDIR)/build/busybox-$(BUSYBOX_VER)

UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
  GNUBIN  := /opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:
  export PATH := $(GNUBIN)$(PATH)
  KMAKE   := gmake ARCH=riscv CROSS_COMPILE=$(CROSS) LD=ld.lld HOSTCFLAGS="-I$(CURDIR)/kernel/hostinc -D_UUID_T -D__GETHOSTUUID_H"
else
  KMAKE   := $(MAKE) ARCH=riscv CROSS_COMPILE=$(CROSS)
endif

.PHONY: all flash clean
all: images/stub.bin images/sonata-ram.dtb images/kernel.bin images/rootfs.romfs

images/stub.bin: stub.S stub.ld build_stub.sh
	CROSS=$(CROSS) ./build_stub.sh $@ -DNO_PMP     # this SoC's VexRiscv has no PMP

images/sonata-ram.dtb: kernel/sonata-ram.dts
	dtc -I dts -O dtb -o $@ $< 2>/dev/null

$(LINUX)/.git:
	mkdir -p $(LINUX) && cd $(LINUX) && git init -q && git remote add origin $(KERNEL_URL)
	cd $(LINUX) && git -c http.version=HTTP/1.1 fetch -q --depth 1 origin $(KERNEL_REV) && git checkout -q FETCH_HEAD

$(LINUX)/arch/riscv/boot/Image: $(LINUX)/.git images/sonata-ram.dtb kernel/ram-additions.config $(wildcard kernel/drivers/*/*.c kernel/drivers/*/*/*/*/*.[ch])
	cp -r kernel/drivers/* $(LINUX)/drivers/
	grep -q sonata_lcdcon $(LINUX)/drivers/video/Makefile || echo 'obj-y += sonata_lcdcon.o' >> $(LINUX)/drivers/video/Makefile
	grep -q sonata_lcdfb $(LINUX)/drivers/video/fbdev/Makefile || echo 'obj-$$(CONFIG_FB_SONATA) += sonata_lcdfb.o' >> $(LINUX)/drivers/video/fbdev/Makefile
	grep -q FB_SONATA $(LINUX)/drivers/video/fbdev/Kconfig || printf 'config FB_SONATA\n\tbool "Sonata board LCD frame buffer"\n\tdepends on FB && OF\n\tselect FB_IOMEM_HELPERS\n\thelp\n\t  160x128 RGB565 frame buffer of the Sonata LCD text/graphics block.\n' >> $(LINUX)/drivers/video/fbdev/Kconfig
	cp images/sonata-ram.dtb $(LINUX)/arch/riscv/boot/dts/litex/sonata.dtb
	base64 $(LINUX)/arch/riscv/boot/dts/litex/sonata.dtb > $(LINUX)/arch/riscv/boot/dts/litex/sonata.dtb.b64
	cd $(LINUX) && $(KMAKE) tinyconfig && \
	  scripts/kconfig/merge_config.sh -m .config $(CURDIR)/kernel/ram-additions.config && \
	  scripts/config --disable XIP_KERNEL --disable BLK_DEV_INITRD --enable BUILTIN_DTB \
	    --set-str BUILTIN_DTB_SOURCE litex/sonata --enable MTD --enable MTD_ROM --enable MTD_BLOCK \
	    --enable MTD_PHYSMAP --enable MTD_PHYSMAP_OF --set-val MISC_FILESYSTEMS y --enable ROMFS_FS && \
	  $(KMAKE) olddefconfig && $(KMAKE) -j$(JOBS) Image

images/kernel.bin: images/stub.bin $(LINUX)/arch/riscv/boot/Image
	cat images/stub.bin $(LINUX)/arch/riscv/boot/Image > $@

# ---- userland: musl and BusyBox, built with the same riscv64-elf-gcc (a bare-metal compiler) used as a riscv32
# Linux/musl cross compiler: build/rv32-gcc adds musl's headers (and -D__linux__, which a bare-metal gcc does not
# define) when compiling and musl's startup files and libc when linking. rv32imac because libgcc has no rv32ima
# multilib; the CPU has compressed instructions.
build/musl-$(MUSL_VER).tar.gz:
	mkdir -p build && curl -fsSL -o $@ http://musl.libc.org/releases/musl-$(MUSL_VER).tar.gz

build/busybox-$(BUSYBOX_VER).tar.bz2:
	mkdir -p build && curl -fsSL -o $@ https://busybox.net/downloads/busybox-$(BUSYBOX_VER).tar.bz2

# Linux kernel headers for musl and BusyBox, from the kernel tree built above
$(SYSROOT)/usr/include/linux/version.h: $(LINUX)/.git
	cd $(LINUX) && $(KMAKE) headers_install INSTALL_HDR_PATH=$(SYSROOT)/usr

$(SYSROOT)/usr/lib/libc.a: build/musl-$(MUSL_VER).tar.gz $(SYSROOT)/usr/include/linux/version.h
	cd build && tar xzf musl-$(MUSL_VER).tar.gz
	cd build/musl-$(MUSL_VER) && CC=$(CROSS)gcc CFLAGS="-march=rv32ima_zicsr_zifencei -mabi=ilp32 -O2" \
	  ./configure --target=riscv32 --prefix=$(SYSROOT)/usr --syslibdir=$(SYSROOT)/lib --disable-shared && \
	  $(MAKE) -j$(JOBS) AR=$(CROSS)ar RANLIB=$(CROSS)ranlib && $(MAKE) install AR=$(CROSS)ar RANLIB=$(CROSS)ranlib

build/rv32-gcc: $(SYSROOT)/usr/lib/libc.a
	printf '%s\n' '#!/bin/sh' \
	  'SYS=$(SYSROOT)/usr' \
	  'CC="$(CROSS)gcc -march=rv32imac -mabi=ilp32"' \
	  'INC="-D__linux__=1 -D__gnu_linux__=1 -D__unix__=1 -nostdinc -isystem $$SYS/include -isystem '"$$($(CROSS)gcc -print-file-name=include)"'"' \
	  'for a in "$$@"; do case "$$a" in -c|-E|-S|-M|-MM|-r|-dumpmachine|-dumpversion|-print-*|--version|-v) exec $$CC $$INC "$$@";; esac; done' \
	  'exec $$CC $$INC -static -nostdlib -nostartfiles $$SYS/lib/crt1.o $$SYS/lib/crti.o "$$@" -L$$SYS/lib -lc -lgcc $$SYS/lib/crtn.o' > $@
	chmod +x $@

$(BB)/busybox: build/busybox-$(BUSYBOX_VER).tar.bz2 build/rv32-gcc userland/busybox.config
	cd build && tar xjf busybox-$(BUSYBOX_VER).tar.bz2
	cp userland/busybox.config $(BB)/.config
	cd $(BB) && $(MAKE) oldconfig HOSTCC=cc </dev/null >/dev/null
	cd $(BB) && PATH=$(CURDIR)/build:$$PATH $(MAKE) -j$(JOBS) CC=rv32-gcc HOSTCC=cc AR=$(CROSS)ar STRIP=$(CROSS)strip
	cd $(BB) && PATH=$(CURDIR)/build:$$PATH $(MAKE) busybox.links CC=rv32-gcc HOSTCC=cc

# The base romfs has no /sbin/init (this busybox has no init applet): tools/romfs_add.py adds a shell-script init
# that mounts /proc and /sys and starts a shell, replaces /bin/busybox with the one built above, links every applet
# to it and installs the udhcpc script.
# also writes rtl/lcd_fb_ram.v, the LCD frame buffer RAM with the logo as its initial contents (needs a new bitstream)
images/sonata-logo.rgb565: tools/gen_logo.py ../../sonata-lib/font8x8_basic.h
	python3 tools/gen_logo.py $@ ../rtl

images/rootfs.romfs: tools/romfs_add.py $(ROOTFS_BASE) $(BB)/busybox images/sonata-logo.rgb565 userland/showlogo
	python3 -I tools/romfs_add.py $(ROOTFS_BASE) $@ --busybox $(BB)/busybox --links $(BB)/busybox.links \
	  --udhcpc-script $(BB)/examples/udhcp/simple.script \
	  --file /usr/share/sonata-logo.rgb565=images/sonata-logo.rgb565 --file /usr/bin/showlogo=userland/showlogo:x

# Sizes come from the files: flash_write needs the exact length, flash_erase_range the length rounded up to the
# 64 KB erase sector, and mem_cmp counts 32-bit words.
flash:
	@echo "tools/tftpd.py <dir containing the images> serves TFTP on this machine (the DIP switches select the server"
	@echo "by its last octet). At the BIOS prompt (press ESC at the boot countdown):"
	@for f in kernel.bin:0x0:0x02000000 rootfs.romfs:0x5C0000:0x025C0000; do \
	  name=$${f%%:*}; rest=$${f#*:}; off=$${rest%%:*}; map=$${rest#*:}; \
	  size=$$(wc -c < images/$$name | tr -d ' '); \
	  erase=$$(printf '0x%x' $$(( ($$size + 0xffff) / 0x10000 * 0x10000 ))); \
	  echo "  tftpget $$name 0x40000000          # must print: loaded $$size bytes"; \
	  echo "  flash_erase_range $$off $$erase"; \
	  echo "  flash_write $$off 0x40000000 $$size"; \
	  echo "  mem_cmp $$map 0x40000000 $$(( $$size / 4 ))   # words; must print: same content"; \
	done
	@echo "  reboot        # boots Linux from flash with no network"

clean:
	rm -rf build images/stub.* images/kernel.bin images/sonata-ram.dtb images/rootfs.romfs
