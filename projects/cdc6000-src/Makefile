# Running the CDC 6000 Pascal compiler on the VC707, as synthgui builds it.
#
#   make hello       compile hello.pas on the board
#   make selfhost    compile the compiler on the board, check its output is the
#                    emulator's and that the compiler built from it is the one
#                    that ran (the self-hosting fixed point)
#
# The board must hold no other program's state: each target reprograms it.
# CDC is the cdc6000 repository (its emulator, compiler source and image
# tools); BIT and LOADER are synthgui's build and openFPGALoader.

SYNTHGUI ?= $(abspath ../..)
CDC      ?= $(HOME)/cdc6000
BIT      ?= $(HOME)/synthgui-work/cdc6000/vc707_cdc_top.bit
LOADER   ?= $(SYNTHGUI)/build-deps/prefix/bin/openFPGALoader
PORT     ?= /dev/ttyUSB2
OUT      ?= out

RUN = python3 cdcrun.py --bit $(BIT) --loader $(LOADER) --port $(PORT)

.PHONY: hello selfhost clean

hello:
	$(RUN) hello.pas

selfhost: $(OUT)/board/pasclgo.out $(OUT)/emu/pasclgo.out
	python3 $(CDC)/host/pasclgo2img.py $(OUT)/board/pasclgo.out $(CDC)/host/stage2/parmlist.out \
		$(OUT)/board/next.img --compiler
	python3 selfhost_check.py mem.hex $(OUT)/board $(OUT)/emu $(CDC)/host/runtime.img \
		$(CDC)/host/stage2/parmlist.out $(OUT)/board/next.img

# the board compiles the compiler's source (about 20 s)
$(OUT)/board/pasclgo.out: mem.hex
	mkdir -p $(OUT)/board
	$(RUN) $(CDC)/host/pascal.cdc --timeout 900 --save $(OUT)/board --listing $(OUT)/board/listing.txt

# the emulator does the same from the same memory image
$(OUT)/emu/pasclgo.out: $(OUT)/mem.img
	mkdir -p $(OUT)/emu
	$(CDC)/host/cdcemu $(CDC)/host/runtime.img $(OUT)/mem.img -i $(CDC)/host/pascal.cdc \
		-o $(OUT)/emu/listing.txt -d $(OUT)/emu

$(OUT)/mem.img: mem.hex
	mkdir -p $(OUT)
	python3 hex2img.py mem.hex $@

clean:
	rm -rf $(OUT)
