#!/bin/bash
# The partial-reconfiguration flow for one window circuit; see nextpnr's
# docs/xilinx-partial-reconfiguration.md.  Each step can run alone: pr_flow.sh <step>
#   merge    harness JSON (block as a black box) + block JSON -> harness-merged.json
#   harness  P&R with the window reserved -> harness.fasm/.bit, interface.txt
#   window   the block alone on the window chipdb, pinned to the interface -> window.fasm
#   partial  merged FASM -> frames -> ICAP image, checked against the harness frames
#
# Required: RUN (run directory), HARNESS_JSON, BLOCK_JSON, XDC.  RUN/win/ holds chipdb-win.bin,
# window-map.json and window.xdc (nextpnr's gen/xilinx_gen.py --window).
# Optional: WINDOW, PREFIX, INSTANCE, PINS ("cell=bel ...", e.g. an MMCM with fabric outputs),
# NPNR, H (harness output dir), W (window output dir), SYNTHGUI (the built-in tools, default build/synthgui).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
: "${RUN:?set RUN}" "${HARNESS_JSON:?set HARNESS_JSON}" "${BLOCK_JSON:?set BLOCK_JSON}" "${XDC:?set XDC}"
NPNR=${NPNR:-$ROOT/build-deps/nextpnr/nextpnr-himbaechel}
CHIPDB=${CHIPDB:-$ROOT/build-deps/nextpnr/share/himbaechel/xilinx/chipdb-xc7vx485t.bin}
DELAY_MATRIX=${DELAY_MATRIX:-$HERE/delay-matrix-xc7vx485t.txt}
PART=${PART:-xc7vx485tffg1761-2}; DEVICE=${DEVICE:-xc7vx485t}; FAMILY=${FAMILY:-virtex7}
DB=$ROOT/deps/prjxray-db/$FAMILY; TILEGRID=$DB/$DEVICE/tilegrid.json
WINDOW=${WINDOW:-354,53,390,103}; PREFIX=${PREFIX:-at_block.}; INSTANCE=${INSTANCE:-at_block}
H=${H:-$RUN/harness/pnr}; W=${W:-$RUN/window}; mkdir -p "$H" "$W"
SYNTHGUI=${SYNTHGUI:-$ROOT/build/synthgui}
F2B=$ROOT/build-deps/prjxray/tools/xc7frames2bit
bits() { "$F2B" --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file "$1" --output_file "$2"; }
step=${1:-all}
if [ "$step" = merge ] || [ "$step" = all ]; then
  "$SYNTHGUI" --tool pr-block-json merge --harness "$HARNESS_JSON" --block "$BLOCK_JSON" --instance "$INSTANCE" --prefix "$PREFIX" --out "$H/harness-merged.json"
  [ -z "${PINS:-}" ] || "$SYNTHGUI" --tool pin-cells "$H/harness-merged.json" $PINS
fi
if [ "$step" = harness ] || [ "$step" = all ]; then
  "$NPNR" --device "$PART" --chipdb "$CHIPDB" --json "$H/harness-merged.json" -o xdc="$XDC" \
    --router router2 --timing-allow-fail -o hold-fix --placer-heap-timingweight 100 --placer-heap-congestion-spread \
    -o delay-matrix="$DELAY_MATRIX" -o pr-window="$WINDOW" -o pr-cells="$PREFIX" -o pr-interface="$H/interface.txt" \
    -o fasm="$H/harness.fasm" -o placement="$H/harness_placement.json" --write "$H/harness.json" > "$H/pnr.log" 2>&1
  grep "PR window" "$H/pnr.log" | tail -15
  "$SYNTHGUI" --tool fasm2frames --part "$PART" --db-root "$DB" "$H/harness.fasm" "$H/harness.frames"
  bits "$H/harness.frames" "$H/harness.bit"
fi
if [ "$step" = window ] || [ "$step" = all ]; then
  "$SYNTHGUI" --tool pr-block-json window --block "$BLOCK_JSON" --harness "$HARNESS_JSON" --instance "$INSTANCE" \
    --interface "$H/interface.txt" --map "$RUN/win/window-map.json" --prefix "$PREFIX" --out "$W/window.json" --reserve "$W/reserve.txt"
  "$NPNR" --device "$PART" --chipdb "$RUN/win/chipdb-win.bin" --json "$W/window.json" -o xdc="$RUN/win/window.xdc" \
    --router router2 --timing-allow-fail -o hold-fix -o clock-tree=off -o delay-matrix=off -o pr-reserve="$W/reserve.txt" \
    -o fasm="$W/window.fasm" --write "$W/window-routed.json" > "$W/pnr.log" 2>&1
  tail -5 "$W/pnr.log"
fi
if [ "$step" = partial ] || [ "$step" = all ]; then
  "$SYNTHGUI" --tool pr-partial --tilegrid "$TILEGRID" --window "$WINDOW" merge "$H/harness.fasm" "$W/window.fasm" "$W/merged.fasm"
  "$SYNTHGUI" --tool fasm2frames --part "$PART" --db-root "$DB" "$W/merged.fasm" "$W/merged.frames"
  "$SYNTHGUI" --tool pr-partial --tilegrid "$TILEGRID" --window "$WINDOW" extract "$W/merged.frames" "$W/window.icap" --ref "$H/harness.frames" --frames-out "$W/window.frames"
  bits "$W/merged.frames" "$W/merged.bit"   # the same design as a full bitstream, for a JTAG cross-check
fi
