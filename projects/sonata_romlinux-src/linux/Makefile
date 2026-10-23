# Builds the Linux side of sonata_romlinux: the files in images/ are built with this Makefile.
#
#   images/stub.bin        4 KB M-mode stub (stub.S, GPL-compatible source in this directory)
#   images/kernel.bin      stub.bin + the RAM kernel Image; what the BIOS boots from flash or over TFTP
#   images/sonata-ram.dtb  the device tree built into the kernel (kernel/sonata-ram.dts)
#   images/rootfs.romfs    the read-only root filesystem (romfs) for the flash `rootfs` partition
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
	cd $(LINUX) && git fetch -q --depth 1 origin $(KERNEL_REV) && git checkout -q FETCH_HEAD

$(LINUX)/arch/riscv/boot/Image: $(LINUX)/.git images/sonata-ram.dtb kernel/ram-additions.config $(wildcard kernel/drivers/*/*.c kernel/drivers/*/*/*/*/*.[ch])
	cp -r kernel/drivers/* $(LINUX)/drivers/
	grep -q sonata_lcdcon $(LINUX)/drivers/video/Makefile || echo 'obj-y += sonata_lcdcon.o' >> $(LINUX)/drivers/video/Makefile
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

# The base romfs has no /sbin/init (this busybox has no init applet): tools/romfs_add.py adds a shell-script init
# that runs /etc/init.d/rcS and then a shell.
images/rootfs.romfs: tools/romfs_add.py $(ROOTFS_BASE)
	python3 -I tools/romfs_add.py $(ROOTFS_BASE) $@

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
