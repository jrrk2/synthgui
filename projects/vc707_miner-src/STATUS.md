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

# 2026-11-02: first full 4-lane bitstream through nextpnr's router; placement is the gap

Reference: Vivado 2020.1 on the i9 places and routes the identical Verilator
netlist (flat EDIF, `--map-only-edif-flat`) in 7 min, WNS +0.32 ns, and that
bitstream mines on the board.  See the `vivado-reference-flow` notes: site table,
`-o preplaced=` import of Vivado's placement.

## Results

| placement (same netlist)            | HPWL  | slices | DSP->adder | post-place clk_mac | routed |
|-------------------------------------|-------|--------|------------|--------------------|--------|
| Vivado (route.dcp)                  | 2.04M | 19.3k  | 5-10 tiles | met                | Vivado 7 min; **nextpnr 39 min, 84 passes, 99.99 MHz, mines on the board** |
| HeAP as configured (beta 0.5)       | 3.30M | 25.9k  | 27-38      | 112 MHz            | not in 7 h (old router); new router still in pass 1 after 1.5 h |
| HeAP beta 0.7                       | 2.79M |        |            | 147 MHz            | |
| HeAP + DSP/BRAM site refinement     | 3.16M |        | 9-11       | 112 MHz            | |
| HeAP, no extra flags                | 2.45M | 20.3k  | 25-46      | 136-140 MHz        | routing on the i9 (`~/legacy4s`, `~/legacy4t`) |
| ... + unmerged registers            |       |        |            | 169 MHz            | routing on the i9 (`~/legacy4u`) |

`--placer static` gives the same 2.45M: the uarch's BRAM pass re-places everything with HeAP afterwards.
The two flags the projects carried (`--placer-heap-timingweight 60 --placer-heap-congestion-spread`) cost +35% wirelength here and are dropped from projects/vc707_miner*.json.

The router on Vivado's placement explores ~130 wires per arc; on HeAP's, 10x
more.  The placer is the bottleneck, not the router.

## nextpnr (deps/nextpnr)

Branch `synthgui`: dense wire index + per-tile-type pip tables (router ~1.5x),
router2 progress lines and quadtree partitions (16 threads), fixes for fully
pinned placements, `sparse_refine.cc` (DSP/BRAM moved to the nearest free site
minimising HPWL; `-o sparse-refine=off`).

Branch `routethru` (on top): carry DI inputs on the bypass pin instead of a
buffer LUT (`-o carry-di-bypass=off`), FF route-through legality with a chipdb
pip into the FF mux (`-o ff-routethru=off`), 26 unit tests, and the
`vc707_routethru` project (pinned FF pairs, LVS-proved).  Quick set passes.

## Merged registers

The mapper merges the four lanes' identical matrix registers into one bank
(4,880 flip-flops, flagged `MERGED_EQUIV`); with compact lanes a quarter of the
nets then cross the die centre and route single-threaded (42k serial nets in
pass 1).  Vivado's routed design replicates only 21 registers (the keccak FSM
bits) and copes by interleaving the lanes.  nextpnr now splits any flip-flop
whose placed sinks cluster far apart (`replicate.cc`, `-o replicate=off`), the
copies named `<cell>$dup<n>` and proved by LVS against their originals; the
run on the i9 (`~/legacy4v`) measures it on the flagged netlist.

## Next

1. Finish and route the static-placer run; if it meets 100 MHz, that is the
   first fully open 4-lane bitstream.
2. Place DSPs first (assignment from the analytical solution, then fix and
   re-place the logic) if DSP->adder distance still lags Vivado.
3. HeAP beta 0.7 as the xilinx default once validated on the quick set.
