#!/usr/bin/env bash
# run.sh [workdir] [plusargs...] -- build and run tb_miner with Verilator.
# LANES=<n> (default 1) sets miner_core's lane count.
# The job comes from gen_job.py (needs ~/heavyhash/verify_pow.py).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); src=$here/..
work=${1:-$here/work}; shift || true
VERILATOR=${VERILATOR:-verilator}
mkdir -p "$work"
python3 "$here/gen_job.py" "$work/job"
LANES=${LANES:-1}
$VERILATOR --binary --timing -DTB_LANES=$LANES -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  --top-module tb_miner --Mdir "$work/obj" -o tb_miner \
  "$here/RAMB36E1.v" \
  "$src/keccak_pkg.sv" "$src/heavyhash_pkg.sv" "$src/keccak_round.sv" "$src/keccak256.sv" \
  "$src/heavyhash_matrix.sv" "$src/heavyhash_pipeline.sv" "$src/heavyhash_lanes.sv" \
  "$src/mine_ctrl.sv" "$src/framing_miner.sv" "$src/miner_core.sv" \
  "$here/sgmii_soc_stub.sv" "$here/tb_miner.sv" > "$work/build.log" 2>&1 \
  || { tail -30 "$work/build.log"; exit 1; }
"$work/obj/tb_miner" +job="$work/job" "$@" | tee "$work/run.log"
grep -q "tb: PASS" "$work/run.log"
