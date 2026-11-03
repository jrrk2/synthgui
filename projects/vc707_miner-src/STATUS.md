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

## Placement figure of merit (2026-11-03, overnight)

`scripts/placement_fom.py` on the same netlist in Vivado's tile grid.  hpwl is
x-weighted (x counts double, HeAP's weighting); over250 is the RUDY demand
above 250 per occupied tile, averaged per cell; hot% the share of cells in
tiles above 300.  Routing outcomes from the i9 (router2, 16 threads):

| placement                          | hpwl   | long nets | hot% | over250 | pass 1       | pass 2 overused | outcome |
|------------------------------------|--------|-----------|------|---------|--------------|-----------------|---------|
| Vivado                             | 3.37M  | 5.5k      | 4.9  | 6.5     | 20 min, 146k | 34k             | 84-155 passes, 35-39 min, mines |
| HeAP no flags (static placer)      | 3.55M  | 5.5k      | 8.0  | 11.8    | ~6 h, 176k   | 92k (4.5 h)     | not converging |
| HeAP timingweight 60 + cong-spread | 4.10M  | 7.3k      | 11.2 | 15.7    | hours        |                 | not converging |
| unmerged registers, no flags       |        |           |      |         | ~6 h, 197k   | pass 2 >9 h     | killed |
| replication, old criterion         |        |           |      |         | ~6 h, 204k   | pass 2 >9 h     | killed |
| OpenROAD global place, density 0.5 | 6.24M  | 14.3k     | 0.9  | 2.4     | 5 h 13, 171k | 61k nets        | running (`~/orroute`) |
| user's topographical placer (SA)   | 9.70M  | 24.6k     | 39.1 | 44.8    | >3 h         |                 | running (`~/toporoute`) |
| **HeAP cong-spread only**          | 3.93M  | 8.8k      | 1.7  | 2.4     | 19 min, 145k | 33.5k (1 h 45)  | **routed: 9 passes, 2 h 59 total, 90.6 MHz** (`~/legacy4z`) |
| **HeAP beta 0.7 + cong-spread**    | 3.24M  | 5.8k      | 2.2  | 3.6     | 20 min, 149k | 38.3k (1 h 18)  | **routed: 42 passes, 3 h 08 total, 97.8 MHz** (`~/legacy4aa`) |

What the table says:

- Local overflow (over250, hot%) orders the outcomes among placements of
  similar wirelength; wirelength alone does not (no-flags HeAP has nearly
  Vivado's HPWL and does not route).  Long wires alone do not either: the
  OpenROAD placement has the lowest overflow but 1.8x the wirelength and its
  first pass took 5 h.  Both have to be low: the FOM is overflow at
  Vivado-like HPWL.
- `--placer-heap-congestion-spread` *on its own* (the project flags also
  carried `--placer-heap-timingweight 60`, and that was the harmful one) is
  the first nextpnr placement that behaves like Vivado's under the router:
  pass 1 in 19 min with the same overused count, pass 2 to 33.5k, zero
  overuse after 9 passes: **the first fully open 4-lane route**, clk_mac
  90.6 MHz.  With beta 0.7 as well, HPWL is below Vivado's and the route
  reaches 97.8 MHz in 42 passes.  Bitstreams for both, as routed (100 MHz,
  fails timing by 2-10%) and MMCM-retimed to 83.3 / 90.9 MHz
  (`scripts/mmcm_retime.py`), are in the scratchpad `cong/legacy4z`,
  `cong/legacy4aa`.  **Board-proven 2026-11-03 06:10:** the beta 0.7 +
  congestion-spread bitstream at 90.9 MHz mines testnet-10 through
  mine_daemon, 137 nonces found, 137 verified in software, 0 failed,
  6.9 MH/s -- the first fully open-flow 4-lane miner.  Both miner projects
  now carry `--placer-heap-beta 0.7 --placer-heap-congestion-spread
  -o replicate=off`.  Placement takes 25-38 min instead of
  about 2 h, because the spread cells legalise quickly (HeAP beta 0.7 alone,
  without the spread, sits in the legaliser at 600 s per iteration).
- The user's topographical placer (System-Verilog-suite `place_lef`, built
  with dune; stamps converted by `scripts/topo_bels2preplaced.py`) places the
  design in 2.5 min but spreads each lane's DSPs over 8-11 columns and
  overlaps the lanes: a bad placement by every measure, kept as the FOM's
  far end.
- Every nextpnr placement still leaves DSPs 27-62 tiles from their adder
  trees (Vivado 5-10); `sparse-refine` brings that to 9-11.

Scratch data: `$SCRATCH/cong/fom_all.txt` (table), `cong/*/analysis.txt`,
`topo/{region,sa,analytic}` (the suite's placements), i9 `~/cong/timeline.txt`
(time-stamped router passes).

## Lane and frequency sweep (2026-11-03, i9, routethru tip, beta 0.7 + congestion-spread)

Vivado routes up to 12 lanes at 125 MHz.  Netlists from the same sources
with `LANES=N` and `MAC_DIV=8|10` (125 / 100 MHz), scratchpad `sweep/`,
runs in `~/sweep/L<N>_M<div>` on the i9 (`queue.sh`, two at a time):

| lanes | clk_mac | cells | DSPs | result |
|---|---|---|---|---|
| 4 | 100 | 109k | 256 | routed, 42 passes, 97.8 MHz, mines (`legacy4aa`) |
| 4 | 125 | 109k | 256 | **identical** to the 100 MHz run pass for pass: 97.8 MHz, 2 h 50 |
| 6 | 100 | 150k | 384 | running |
| 8 | 100 | 194k | 512 | **stuck in pass 1**: parallel phases done in 1 h, then the serial phase (82k nets crossing both midlines) routed 1.4k nets in 2.3 h with the search climbing to 1.2k wires/arc; killed |
| 12 | 100 | 279k | 768 | running (HeAP iteration 1 took 13 min) |
| 8, 12 | 125 | | | skipped: a 125 MHz netlist places and routes exactly as the 100 MHz one |

The frequency axis is degenerate: HeAP's and router2's timing weighting is
relative, so the constraint changes nothing and the open flow delivers
~98 MHz at 4 lanes whatever is asked.  The lane threshold with this
configuration is between 4 and 8: at 8 the merged matrix bank fanning out to
eight compact lanes puts the die-centre crossing beyond what the congestion
spread relieves.  Remedies to try at 8 lanes: `replicate` with the fixed
threshold (split the bank per lane) and `-o macro-region` per lane.

## Next

1. Done 2026-11-03: `cong/legacy4aa/vc707_miner_90.bit` mines on the board
   (1,082 nonces, all verified); both miner projects carry
   `--placer-heap-beta 0.7 --placer-heap-congestion-spread -o replicate=off`;
   LVS of the legacy4z FASM against the synthesis: 79,777 proved, 0 differ,
   0 unknown (2 h 33 min; 39,012 registers matched, clock edges and sources
   agree).  Next: close the last 2% to 100 MHz (DSP-first placement, or a
   timing weight that does not undo the spread), and consider the
   congestion spread as the xilinx default after the quick set.
2. Place DSPs first (assignment from the analytical solution, then fix and
   re-place the logic): DSP->adder distance still lags Vivado 5x.
3. Make the congestion spread absolute rather than median-relative (the
   prototype halves capacity above the median tile; Vivado's own placement
   keeps over250 at 6.5 with fewer slices), and validate on the quick set.
