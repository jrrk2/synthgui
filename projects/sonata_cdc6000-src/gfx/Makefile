# Pascal programs for the Sonata's LCD, on the CDC 6000 core (sonata_cdc6000.json).
#
#   make                    lcd.pas -> out/mem.hex, the memory of the core with that program in place of the compiler
#   make PROGRAM=other.pas  another program
#   make preview            what the program draws, out/lcd.png, from the cdc6000 emulator (no board needed)
#   make go                 out/mem_go.hex, the memory of the board that compiles and runs a program sent to it: ../mem.hex is this
#                           (the compiler and the run time of cdc6000's host/mkrt.py --go); make gopreview shows the emulator doing it
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

.PHONY: all preview go gopreview clean
all: $(OUT)/mem.hex
preview: $(OUT)/lcd.png
go: $(OUT)/mem_go.hex
gopreview: $(OUT)/lcd_go.png

$(CDC)/host/cdcemu: $(CDC)/host/cdcemu.c
	cd $(CDC)/host && gcc -O2 -o cdcemu cdcemu.c -lm
$(CDC)/host/runtime.img: $(CDC)/host/mkrt.py $(CDC)/host/cdcasm.py
	cd $(CDC)/host && python3 mkrt.py runtime.asm && python3 cdcasm.py runtime.asm runtime.img

# the compiler of ../mem.hex without its run time: the boot words 1..3 and everything from the user area, 2049, up
$(OUT)/compiler.img: ../mem.hex
	mkdir -p $(OUT)
	python3 $(HEX2IMG) ../mem.hex $(OUT)/all.img
	python3 -c "import sys; [sys.stdout.write(l) for l in open('$(OUT)/all.img') if int(l.split()[0], 8) <= 3 or int(l.split()[0], 8) >= 2049]" > $@

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

# the same, with the run time that keeps the compiler's output and starts it (host/mkrt.py --go in the cdc6000 repository)
$(OUT)/runtime_go.img: $(CDC)/host/mkrt.py $(CDC)/host/cdcasm.py
	mkdir -p $(OUT)
	python3 $(CDC)/host/mkrt.py $(OUT)/runtime_go.asm --go --b4=$(B4)
	python3 $(CDC)/host/cdcasm.py $(OUT)/runtime_go.asm $@

$(OUT)/mem_go.hex: $(OUT)/runtime_go.img $(OUT)/compiler.img
	python3 $(CDC)/fpga/vc707/mkmem.py $(OUT)/runtime_go.img $(OUT)/compiler.img $@

$(OUT)/lcd_go.png: $(PROGRAM) $(OUT)/mem_go.hex $(OUT)/runtime_go.img $(CDC)/host/cdcemu
	python3 $(HEX2IMG) $(OUT)/mem_go.hex $(OUT)/compiler_go.img
	mkdir -p $(OUT)/rungo
	$(CDC)/host/cdcemu $(OUT)/runtime_go.img $(OUT)/compiler_go.img -i $(PROGRAM) -o $(OUT)/rungo.txt -d $(OUT)/rungo
	python3 lcdview.py $(OUT)/rungo/lcd.out $@

$(OUT)/lcd.png: $(OUT)/program.img
	mkdir -p $(OUT)/run
	$(CDC)/host/cdcemu $(CDC)/host/runtime.img $(OUT)/program.img -o $(OUT)/run.txt -d $(OUT)/run
	python3 lcdview.py $(OUT)/run/lcd.out $@

clean:
	rm -rf $(OUT)
