# vc707_miner: where the multi-lane work stands (2026-11-01)

The 1-lane miner works on the board: testnet-10 via `host/ws_tls_relay.py` to
`vector-10.kaspa.green`, every block accepted, 2.0-2.3 MH/s at 100 MHz, and
`clk_mac` raised to 111.1 MHz after routing with `scripts/mmcm_retime.py`.
The 4-lane work below was stopped on a 31 GB machine: three P&R runs of this
size at once ran it out of memory.  Run one at a time, and expect a 4-lane
run to need well over 10 GB.

## Runs to repeat on the bigger machine

| project | what it is | where it got to |
| --- | --- | --- |
| `projects/vc707_miner_legacy4.json` | flat legacy flow, 4 lanes, parallel config fan-out, no BUFHCE (`miner_core_legacy.sv`, `vc707_miner_legacy.xdc`) | placed: `clk_mac` 114.98 MHz est. (PASS at 100); killed before routing |
| `projects/vc707_miner.json` (LANES=4) | step 1: serial config chain, one BUFHCE per lane, flat synthesis | first placement: lane clocks 60.7-89.6 MHz est. (FAIL at 100); killed in the second placement pass |

    cd ~/synthgui
    QT_QPA_PLATFORM=offscreen build/synthgui --project projects/vc707_miner_legacy4.json --run synth,pnr,bit

If routed `clk_mac` falls short of 100 MHz, lower it with `mmcm_retime.py
--pnr-log ... --clock clk_mac` instead of routing again.  Each lane should give
roughly 2.8-3.1 MH/s.  Program over JTAG only (the `program` step), not BPI flash.

The step-1 run places worse than the legacy one because only a lane's clocked
cells (its flip-flops) are confined to the BUFHCE's clock region; its LUTs,
CARRY4s, DSPs and BRAMs spread outside it and its paths get long.

## Hard-macro flow (step 2), in progress

- `heavyhash_lane.sv` is one lane; `heavyhash_lanes.sv` chains N of them
  (packed chain arrays: unpacked arrays driven only through instance outputs
  are dropped by the mapper -- not yet fixed there).
- The lane is mapped once on its own, with one ABC run (`verilator
  --top-module heavyhash_lane --map-only-no-iobuf`); the top is mapped with
  `--struct-only-blackbox heavyhash_lane`; `flow/lane_macro.py merge` splices
  the lane into each instance under an `<instance>__` prefix.  After nextpnr's
  packing every lane has the same 39,522 cell names (needs nextpnr `b3f828c1`).
- Gate test: `LANES=2 sim/run_gate.sh <dir> --macro` passes.

Next:

1. nextpnr: constrain *all* cells under a prefix to the clock region of a
   given buffer (proposed `-o macro-region=<prefix>:<buffer cell>`), then redo
   the one-lane template placement.
2. nextpnr: stamp that placement onto the other lanes at whole clock-region
   offsets (52 tile rows per region), as a user-defined hard macro.
3. Move lane 3 to X1Y6 (`BUFHCE_X1Y72`) so all four lanes use the right-half
   template.

## Not yet pushed

    git -C ~/synthgui/deps/verilator push origin synthesis
    git -C ~/synthgui/deps/nextpnr push origin synthgui
    git -C ~/synthgui push origin vc707-miner

The nextpnr commits are `b3f828c1` (carry S-input duplicate names) and
`55803c24` (hold-fix net-alias crash in vc707_ethmin).  The Verilator commit
adds `--map-only-no-iobuf`.

## Open question: CI timing regression

cdc6000, vc707_cdc_eth and vc707_ethmin miss timing in CI after the tool
update.  Two vc707_ethmin P&R runs (old vs new Verilator netlist, same
nextpnr) were left routing to tell whether Verilator or nextpnr is the cause;
repeat them if their results are lost.
