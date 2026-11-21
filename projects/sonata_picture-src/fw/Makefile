# The picture program and its ROM image.
#
#   make                              picture.elf, and ../gen_soc_rom.init from pictures/sonata-logo.rgb565
#   make PICTURE=my.ppm IMAGE=/tmp/rom.init    another picture (raw 160x128 RGB565 or binary PPM), another output
#   make ROMFS=- INTERVAL=5                   the built-in picture alone / a 5 s interval
#   make test                         run the program under QEMU and compare the frame it writes with the picture
#
# RVCC is the RISC-V compiler (riscv64-elf-gcc from Homebrew's riscv-gnu-toolchain; the Ubuntu riscv64-unknown-elf-gcc also does),
# HOSTCC builds mkrom for this machine. The core has the C and M extensions (--with-rvc); no floating point, no atomics used.
RVCC      ?= riscv64-elf-gcc
RVOBJCOPY ?= riscv64-elf-objcopy
HOSTCC  ?= cc
PICTURE ?= ../pictures/sonata-logo.rgb565
# the rootfs romfs the flash holds (the ROM Linux's): its photobox frames are shown in turn. ROMFS=- for the built-in picture alone
ROMFS    ?= ../../sonata_romlinux-src/linux/images/rootfs.romfs
INTERVAL ?= 8
IMAGE   ?= ../gen_soc_rom.init
CFLAGS   = -DINTERVAL_S=$(INTERVAL) -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding -fno-pic -nostdlib -nostartfiles -Wall -Wextra

all: $(IMAGE)

# the picture as a raw frame, which picture.S includes: a different picture is a different frame, so a different image.
# Always made again (a picture older than the last one built would not look newer to make), and only replaced when it differs.
frame.rgb565: FORCE mkrom
	./mkrom frame $(PICTURE) $@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi
FORCE:

# the frames in the flash: their offsets, found in the romfs image
photos.S: FORCE mkrom
	./mkrom photos $(ROMFS) $@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

picture.elf: start.S picture.c picture.S photos.S link.ld frame.rgb565
	$(RVCC) $(CFLAGS) -T link.ld -Wl,--no-warn-rwx-segments -o $@ start.S picture.c picture.S photos.S

picture.bin: picture.elf
	$(RVOBJCOPY) -O binary $< $@

mkrom: mkrom.c
	$(HOSTCC) -O2 -Wall -o $@ $<

$(IMAGE): picture.bin mkrom
	./mkrom init picture.bin $@

test: picture.elf
	./test-qemu.sh picture.elf $(PICTURE)

clean:
	rm -f picture.elf picture.bin frame.rgb565 photos.S mkrom

.PHONY: all test clean FORCE
