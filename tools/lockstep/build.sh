#!/bin/bash
# build.sh TOP RTL_DIR NETLIST OUT: gold (RTL) and gate (mapped netlist + gatecells.v) in one lockstep simulator.
#   TOP      cluster module, e.g. VexRiscvLitexSmpCluster_Cc1_..._Fpu4_Rvc
#   RTL_DIR  holds $TOP.v and Ram_1w_1rs_Generic.v
#   NETLIST  ${TOP}_mapped.v from the mapper, with the cluster as the top (--map-only-keep-equivalent-registers keeps names)
# The netlist must have the cluster's own ports, so synthesise the cluster alone rather than cut it from a SoC.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; T=$1; R=$2; G=$3; O=$4; mkdir -p "$O"
VL="verilator --cc --no-timing -Wno-fatal -Wno-lint -Wno-style --trace --top-module $T -O3 --x-initial unique --x-assign 0 -CFLAGS -O1"
$VL --prefix Vgold --Mdir "$O/gold" -DSYNTHESIS "$R/Ram_1w_1rs_Generic.v" "$R/$T.v" > "$O/gold.log" 2>&1
$VL --prefix Vgate --Mdir "$O/gate" "$HERE/gatecells.v" "$G" > "$O/gate.log" 2>&1
make -j6 -C "$O/gold" -f Vgold.mk > "$O/gold-make.log" 2>&1 &
P=$!; make -j6 -C "$O/gate" -f Vgate.mk > "$O/gate-make.log" 2>&1; wait $P
VR=$(verilator -V | sed -n 's/^ *VERILATOR_ROOT *= *//p' | head -1)
g++ -O2 -I"$VR/include" -I"$VR/include/vltstd" -I"$O/gold" -I"$O/gate" "$HERE/lockstep.cpp" "$VR/include/verilated.cpp" "$VR/include/verilated_vcd_c.cpp" "$VR/include/verilated_threads.cpp" \
  "$O/gold/Vgold__ALL.a" "$O/gate/Vgate__ALL.a" -lpthread -latomic -o "$O/lockstep"
# programs: rv32g-g++ -O2 -fno-exceptions -fno-rtti -fno-threadsafe-statics -nostartfiles -Wl,-T,link.ld -Wl,--build-id=none, then objcopy -O binary
