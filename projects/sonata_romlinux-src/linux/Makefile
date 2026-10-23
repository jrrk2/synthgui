# Builds the Linux side of sonata_romlinux: the files in images/ are built with this Makefile.
#
#   images/stub.bin        4 KB M-mode stub (stub.S, GPL-compatible source in this directory)
#   images/kernel.bin      stub.bin + the RAM kernel Image; what the BIOS boots from flash or over TFTP
#   images/sonata-ram.dtb  the device tree built into the kernel (kernel/sonata-ram.dts)
#   images/rootfs.romfs    the read-only root filesystem (romfs) for the flash `rootfs` partition: BusyBox 1.37.0 +
#                          musl 1.2.5, tcc and the examples (userland/), all built from source here
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
JOBS       ?= 8
MUSL_VER   ?= 1.2.5
BUSYBOX_VER ?= 1.37.0
SYSROOT    := $(CURDIR)/build/sysroot
BB         := $(CURDIR)/build/busybox-$(BUSYBOX_VER)
# the on-board C compiler: jrrk2/tinycc (riscv32 port) at the commit pinned in package/tcc/tcc.mk of jrrk2/buildroot
TCC_REV    ?= f7e187ef8084d49fd458a5ecba54868cce24f62c
TCC_URL    ?= https://github.com/jrrk2/tinycc.git
TCC        := $(CURDIR)/build/tinycc

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

# ---- tcc, configured as package/tcc/tcc.mk does (jrrk2/buildroot), built with the same cross compiler. The recipe
# links against the Buildroot toolchain's libc.a and libgcc.a, which GCC compiles with absolute lui/addi addressing
# (-mcmodel=medlow); the port's linker lacks those relocations (HI20, LO12_I, LO12_S), so userland/tcc-riscv32-abs-relocs.patch
# adds them; userland/tcc-static-libgcc.patch links libgcc.a in a static link too (tcc only does it for dynamic links, but
# the soft-float and 64-bit division helpers are needed either way). One flag is added to the recipe's: --tcc-switches=-static,
# because the board has a static libc only (no ld-musl loader), so a dynamically linked a.out cannot run. c2str.exe is a build-time generator and runs on the host; libtcc1.a is built by the cross gcc.
$(TCC)/tcc: build/rv32-gcc $(wildcard userland/tcc-*.patch)
	rm -rf $(TCC) && mkdir -p $(TCC)
	cd $(TCC) && git init -q && git remote add origin $(TCC_URL) && git -c http.version=HTTP/1.1 fetch -q --depth 1 origin $(TCC_REV) && git checkout -q FETCH_HEAD
	cd $(TCC) && for p in $(CURDIR)/userland/tcc-*.patch; do patch -p1 < $$p || exit 1; done
	cd $(TCC) && PATH=$(CURDIR)/build:$$PATH ./configure --prefix=/usr --cpu=riscv32 --targetos=Linux \
	  --cc=rv32-gcc --ar=$(CROSS)ar --config-musl --elfinterp=/lib/ld-musl-riscv32.so.1 --crtprefix=/usr/lib \
	  --sysincludepaths=/usr/include --libpaths=/usr/lib/tcc:/usr/lib --with-libgcc --tcc-switches=-static --extra-cflags="-O2"
	sed -i.bak 's|"libgcc_s.so.1"|"/usr/lib/libgcc.a"|' $(TCC)/config.h && rm -f $(TCC)/config.h.bak
	cd $(TCC) && cc -DC2STR conftest.c -o c2str.exe
	cd $(TCC) && PATH=$(CURDIR)/build:$$PATH $(MAKE) -j$(JOBS) riscv32-libtcc1-usegcc=yes

# the on-board tree: /usr/bin/tcc, its libtcc1.a and headers, musl's headers, crt files, libc.a, libgcc.a
build/tccroot/usr/bin/tcc: $(TCC)/tcc tools/stage_tcc.py
	python3 tools/stage_tcc.py --tinycc $(TCC) --sysroot $(SYSROOT) --libgcc "$$(build/rv32-gcc -print-libgcc-file-name)" \
	  --gcc $(CURDIR)/build/rv32-gcc --strip $(CROSS)strip --out build/tccroot

# also writes rtl/lcd_fb_ram.v, the LCD frame buffer RAM with the logo as its initial contents (needs a new bitstream)
images/sonata-logo.rgb565: tools/gen_logo.py ../../sonata-lib/font8x8_basic.h
	python3 tools/gen_logo.py $@ ../rtl

# The root filesystem is defined here and in userland/skeleton: directories, device nodes, /etc, BusyBox + musl,
# tcc and the examples. /sbin/init is BusyBox's init: userland/skeleton/etc/inittab and init.d/rcS (mounts /proc, /sys
# and a tmpfs /tmp) and a login shell on the serial console with a controlling terminal, so Ctrl-C works.
images/rootfs.romfs: tools/romfs_add.py $(BB)/busybox images/sonata-logo.rgb565 userland/showlogo userland/fbget userland/cc \
	  build/tccroot/usr/bin/tcc $(wildcard userland/src/*) $(wildcard userland/skeleton/etc/*)
	python3 -I tools/romfs_add.py - $@ --busybox $(BB)/busybox --links $(BB)/busybox.links \
	  --dir /tmp --dir /proc --dir /sys --dir /dev --dir /root --dir /mnt --dir /usr/sbin --dir /var \
	  --dev /dev/console=c:5:1 --dev /dev/null=c:1:3 --dev /dev/zero=c:1:5 --dev /dev/tty=c:5:0 --dev /dev/fb0=c:29:0 \
	  --udhcpc-script $(BB)/examples/udhcp/simple.script \
	  --file /usr/share/sonata-logo.rgb565=images/sonata-logo.rgb565 --file /usr/bin/showlogo=userland/showlogo:x \
	  --file /usr/bin/fbget=userland/fbget:x --file /usr/bin/cc=userland/cc:x --tree build/tccroot=/ --tree userland/src=/usr/src \
	  --tree userland/skeleton=/ --symlink /etc/resolv.conf=/proc/net/pnp

# The BIOS command tftpflash streams a TFTP file into the flash (it erases, writes and verifies one 64 KB block at a
# time), so no size is needed and nothing has to fit in RAM.
flash:
	@echo "tools/tftpd.py <dir containing the images> serves TFTP on this machine (the DIP switches select the server"
	@echo "by its last octet). At the BIOS prompt (press ESC at the boot countdown):"
	@echo "  tftpflash kernel.bin 0x0               # $$(wc -c < images/kernel.bin | tr -d ' ') bytes; the kernel_a partition holds 0x540000"
	@echo "  tftpflash rootfs.romfs 0x5C0000        # $$(wc -c < images/rootfs.romfs | tr -d ' ') bytes; the rootfs partition holds 0x1A40000"
	@echo "  reboot        # boots Linux from flash with no network"

clean:
	rm -rf build images/stub.* images/kernel.bin images/sonata-ram.dtb images/rootfs.romfs
