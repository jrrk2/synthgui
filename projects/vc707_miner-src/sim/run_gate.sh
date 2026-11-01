#!/usr/bin/env bash
# run_gate.sh [workdir] [--rtl-lanes] -- tb_miner on the verilator synthesis
# branch's mapped netlist of miner_core (sgmii_soc black-boxed; the stub
# stands in for it), simulated with iverilog.
#
#   --rtl-lanes   also black-box heavyhash_multi and simulate it from RTL:
#                 only framing_miner + mine_ctrl are gates (about 1 min, not ~1 h)
#
# Cell models: ~/synthgui/xc7/cells_sim.v, except RAMB36E1, whose model there
# is a timing-only stub with no memory behind it (it reads z); Vivado's
# unisim RAMB36E1 + glbl are used instead (UNISIM_DIR).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); src=$here/..
work=${1:-$here/work-gate}
rtl_lanes=0; [ "${2:-}" = "--rtl-lanes" ] && rtl_lanes=1
SYNTHGUI=${SYNTHGUI:-$HOME/synthgui}
PREFIX=${PREFIX:-$SYNTHGUI/build-deps/prefix}
UNISIM_DIR=${UNISIM_DIR:-/opt/Xilinx/Vivado/2020.1/data/verilog/src}
X=$SYNTHGUI/xc7
mkdir -p "$work"
python3 "$here/gen_job.py" "$work/job"

bb="BUFG FDCE GTXE2_CHANNEL IBUFDS IBUFDS_GTE2 MMCME2_ADV RAMB36E1 IBUF OBUF sgmii_soc"
[ $rtl_lanes = 1 ] && bb="$bb heavyhash_multi"
args=(); for b in $bb; do args+=(--struct-only-blackbox "$b"); done
hh=("$src/keccak_pkg.sv" "$src/heavyhash_pkg.sv" "$src/keccak_round.sv" "$src/keccak256.sv"
    "$src/heavyhash_matrix.sv" "$src/heavyhash_pipeline.sv" "$src/heavyhash_multi.sv")
eth=("$src/liteeth_sgmii_phy.v" "$src/rgmii_lfsr.sv" "$src/axis_gmii_rx.sv" "$src/axis_gmii_tx.sv"
     "$src/eth_mac_1g.sv" "$src/eth_pkt_buf256.sv" "$src/eth_gmii_retime256.sv" "$src/sgmii_soc_liteeth.sv")
VERILATOR_ROOT=$PREFIX/share/verilator "$PREFIX/bin/verilator_bin" -Wno-fatal --quiet \
  --top-module miner_core --struct-only-report "${args[@]}" \
  --map-only-output "$work/core.json" --map-only-verilog "$work/core_mapped.v" --Mdir "$work/obj" \
  "$X/cells_sim.v" "$X/cells_xtra.v" "${hh[@]}" "$src/mine_ctrl.sv" "${eth[@]}" \
  "$src/framing_miner.sv" "$src/miner_core.sv" > "$work/synth.log" 2>&1
grep -E '%Info: map|%Warning-MAP' "$work/synth.log" || true

sed '/^module RAMB36E1/,/^endmodule/d' "$X/cells_sim.v" > "$work/cells_nobram.v"
rtl=(); [ $rtl_lanes = 1 ] && rtl=("${hh[@]}")
iverilog -g2012 -DGATE -DUNISIM -s tb_miner -s glbl -o "$work/tb_gate" \
  "$work/cells_nobram.v" "$UNISIM_DIR/unisims/RAMB36E1.v" "$UNISIM_DIR/glbl.v" \
  "${rtl[@]}" "$work/core_mapped.v" "$here/sgmii_soc_stub.sv" "$here/tb_miner.sv" \
  > "$work/build.log" 2>&1 || { grep -i error "$work/build.log" | head; exit 1; }
vvp -n "$work/tb_gate" +job="$work/job" | tee "$work/run.log" | grep 'tb:'
grep -q "tb: PASS" "$work/run.log"
