# Pascal programs for the Sonata's LCD, on the CDC 6000 core (sonata_cdc6000.json).
#
#   make                    lcd.pas -> out/mem.hex, the memory of the core with that program in place of the compiler
#   make PROGRAM=other.pas  another program
#   make preview            what the program draws, out/lcd.png, from the cdc6000 emulator (no board needed)
#
# The Pascal source is compiled by the 1972 compiler of ../mem.hex, run on the cdc6000 repository's emulator (CDC=), and the
# image of the result is merged with the runtime into the file that initialises the core's memory (as fpga/vc707/mkmem.py does for
# the compiler).  Put it into a bitstream without place and route with the ROMs tab of the Block RAMs window (or bram-init):
# the project's ROM "core.mem" has this Makefile as its build command.
#
# CDC is the cdc6000 repository (https://github.com/jrrk2/cdc6000): the emulator, the image tools and the runtime are built from it.

CDC     ?= $(HOME)/cdc6000
PROGRAM ?= lcd.pas
OUT     ?= out
# the stack limit: the core here has 32K words of memory (word 3 of mem.hex)
B4      ?= 0x7f00
HEX2IMG  = ../../cdc6000-src/hex2img.py

.PHONY: all preview clean
all: $(OUT)/mem.hex
preview: $(OUT)/lcd.png

$(CDC)/host/cdcemu: $(CDC)/host/cdcemu.c
	cd $(CDC)/host && gcc -O2 -o cdcemu cdcemu.c -lm
$(CDC)/host/runtime.img: $(CDC)/host/mkrt.py $(CDC)/host/cdcasm.py
	cd $(CDC)/host && python3 mkrt.py runtime.asm && python3 cdcasm.py runtime.asm runtime.img

$(OUT)/compiler.img: ../mem.hex
	mkdir -p $(OUT)
	python3 $(HEX2IMG) ../mem.hex $@

# compile on the emulator, taking the compiler's PARMLIST (11 words at its ICO+1, 2048) from the memory it leaves
$(OUT)/pasclgo.out: $(PROGRAM) $(OUT)/compiler.img $(CDC)/host/cdcemu $(CDC)/host/runtime.img
	mkdir -p $(OUT)/compile
	$(CDC)/host/cdcemu $(CDC)/host/runtime.img $(OUT)/compiler.img -i $(PROGRAM) -o $(OUT)/listing.txt -d $(OUT)/compile \
		-m $(OUT)/compile/mem.img
	@! grep -q '^ \*\*\*\*' $(OUT)/listing.txt || { grep -B1 '^ \*\*\*\*' $(OUT)/listing.txt; echo "compile errors: see $(OUT)/listing.txt"; exit 1; }
	python3 $(CDC)/host/memparm.py $(OUT)/compile/mem.img 2048 $(OUT)/parmlist.out
	cp $(OUT)/compile/pasclgo.out $@

$(OUT)/program.img: $(OUT)/pasclgo.out
	python3 $(CDC)/host/pasclgo2img.py $(OUT)/pasclgo.out $(OUT)/parmlist.out $@ --b4=$(B4)

$(OUT)/mem.hex: $(OUT)/program.img
	python3 $(CDC)/fpga/vc707/mkmem.py $(CDC)/host/runtime.img $(OUT)/program.img $@

$(OUT)/lcd.png: $(OUT)/program.img
	mkdir -p $(OUT)/run
	$(CDC)/host/cdcemu $(CDC)/host/runtime.img $(OUT)/program.img -o $(OUT)/run.txt -d $(OUT)/run
	python3 lcdview.py $(OUT)/run/lcd.out $@

clean:
	rm -rf $(OUT)
