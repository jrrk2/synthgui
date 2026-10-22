# The CDC 6000 with Ethernet: its generated images and the NFS export.
#
#   make images   regenerate cdc_ram_bram.v, cdc_disk_bram.v, pascimg and
#                 pascal.pas with the cdc6000 repository's mkimage_shell.sh
#   make export   copy pascimg and pascal.pas into the NFS export the board
#                 mounts (the shell's compile reloads the compiler from pascimg)
#   make selfhost the board compiles the compiler from the export under its
#                 shell; the compiler image built from its output must be
#                 pascimg, the compiler that ran, byte for byte

CDC    ?= $(HOME)/cdc6000
EXPORT ?= /srv/nfs/vc707/cdc
GEN    ?= gen
BIT    ?= $(HOME)/synthgui-work/cdc6000_eth/vc707_cdc_eth.bit
LOADER ?= $(abspath ../..)/build-deps/prefix/bin/openFPGALoader
PORT   ?= /dev/ttyUSB2

.PHONY: images export selfhost

images:
	rm -rf $(GEN)
	sh $(CDC)/fpga/vc707-eth/mkimage_shell.sh $(abspath $(GEN))
	for f in cdc_ram_bram.v cdc_disk_bram.v; do \
	  { echo '`begin_keywords "1364-2005"  // generated Verilog-2001: names like "do" are not keywords here'; \
	    cat $(GEN)/$$f; echo '`end_keywords'; } > $$f; done
	cp $(GEN)/pascimg $(GEN)/pascal.pas .
	rm -rf $(GEN)

export:
	cp pascimg pascal.pas $(EXPORT)/

selfhost: export
	rm -f $(EXPORT)/pascal.cdc
	python3 cdcshell.py --bit $(BIT) --loader $(LOADER) --port $(PORT) "compile pascal"
	cmp $(EXPORT)/pascal.cdc $(CDC)/host/run/pasclgo.out && echo "the board's object code is the emulator's"
	python3 $(CDC)/host/pasclgo2img.py $(EXPORT)/pascal.cdc $(CDC)/host/run/parmlist.out next.img --compiler --noboot
	cmp next.img pascimg && echo "SELF-HOSTING FIXED POINT ON THE BOARD: the compile's output is the compiler that ran"
	rm -f next.img
