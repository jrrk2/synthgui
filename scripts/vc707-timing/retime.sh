#!/bin/bash
# retime.sh <route dir: cal2|stock2> <mult> <div>: that route's FASM with the BIOS boot clock changed (fasm_rom_patch, no P&R).
# Placement json is build C's: the 32 ROM cells are locked in preplaced.txt, and fasm_rom_patch checks the FASM holds the old ROM.
set -u
D=$HOME/synthgui/runs/2026-11-10-linuxcal; C=$HOME/synthgui/runs/2026-11-04-tune/c; S=$HOME/synthgui/runs/2026-11-05-silicon/retime
X=$HOME/xc7-bitstream-tools/examples/vc707-litex-romlinux; r=$1; tag=m$2d$3; A=$D/retime/$r-$tag; mkdir -p $A
export PATH=$HOME/xc7-bitstream-tools/.venv/bin:$HOME/.local/bin:$PATH
# the BIOS depends only on M/D: reuse 05-silicon's or any earlier route's build for this tag
B=$(ls -d $S/$tag $D/retime/*-$tag 2>/dev/null | while read x; do [ -s $x/new.bin ] && [ -s $x/old.bin ] && echo $x && break; done)
if [ -n "$B" ]; then cp $B/new.bin $A/new.bin; cp $B/old.bin $A/old.bin; else
  args=$(grep -m1 "^#ARGS" $C/args 2>/dev/null | cut -c7-)
  (cd $X && BOOT_MMCM=$2,$3 python3 vc707_atspeed_fpu.py --flow synthgui --output-dir $A/build --no-compile-gateware --build $args > $A/litex.log 2>&1); echo litex $?
  pad() { python3 -c "
import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(d+b'\0'*(0x20000-len(d)))" $1 $2; }
  pad $C/build/software/bios/bios.bin $A/old.bin; pad $A/build/software/bios/bios.bin $A/new.bin
fi
python3 $X/fasm_rom_patch.py $C/pnr/harness_placement.json $D/$r/harness.fasm $A/old.bin $A/new.bin $A/harness.fasm || exit 1
DB=$HOME/synthgui/deps/prjxray-db/virtex7; P=xc7vx485tffg1761-2
$HOME/synthgui/build/synthgui --tool fasm2frames --part $P --db-root $DB $A/harness.fasm $A/harness.frames && $HOME/synthgui/build-deps/prjxray/tools/xc7frames2bit --part_file $DB/$P/part.yaml --part_name $P --frm_file $A/harness.frames --output_file $A/harness.bit
rm -f $A/harness.frames; ls -la $A/harness.bit | cut -c24-; echo RETIMEDONE
