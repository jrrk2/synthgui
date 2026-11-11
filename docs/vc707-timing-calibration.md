# VC707 timing calibration: state and board results (2026-11-11)

A hand-over for the next session. It covers nextpnr's silicon-calibrated timing for the xc7vx485t-2 on the VC707, what it predicts
against two real boards, and the go/no-go rule built from it. Every board figure is a functional observation on one part at one
temperature (typical, not a limit). Run outputs live in `runs/` (git-ignored, same paths on the i9 at 192.168.1.176); the scripts used
are copied to `scripts/vc707-timing/` with their hard-coded `runs/` paths left as they were.

## Versions

| | |
|---|---|
| nextpnr | `deps/nextpnr` at **4c3652aa**, branch `xilinx/timing-cal` (openXC7/nextpnr PR #175), rebased on openXC7 main fd61795b and pushed. Pre-rebase tip kept locally as `backup/timing-cal-pre-rebase-2026-11-10`. |
| prjxray-db | `deps/prjxray-db` at **c4d509e**, branch `synthgui/integration` = `icap-in-use` (ICAP.IN_USE) merged with `virtex7/silicon-timing-cal` (the calibration JSON `virtex7/timings/silicon/xc7vx485t-2.cal.json`) |
| chipdbs | `gen/xilinx_gen.py` with and without `--timing-cal <cal.json>`; built on the i9 in `runs/2026-11-10-rebase/` (`chipdb-cal.bin`, `chipdb-stock.bin`, `run.sh`) |

Fixes on the branch since the calibration landed:
- **fasm.cc, route-through site exit** (b3cf7a87 after the rebase): `write_luts_config` wrote the OUTMUX of a LUT route-through only in tiles
  holding a cell, so a route-through in an empty slice had an open exit. It broke DDR read leveling at every clock on the calibrated
  Linux route. Check any route with `scripts/vc707-timing/rtcheck.py <routed.json> <harness.fasm>` (must report 0 without).
- **RAMB36 arcs** (4c3652aa): clock-to-out of DO*/DOP* and setup of ADDR*/DI*/DIP* named CLKARDCLK/CLKBWRCLK, but the packed cell has
  CLKARDCLKL/U and CLKBWRCLKL/U, and timing.cc drops an arc whose clock is not a port without a warning. Every RAMB36 read was untimed,
  which included the design's worst path. Sys-clock Fmax of the Linux harness on build C's placement: stock 82.56 -> 61.76 MHz,
  calibrated 100.23 -> 70.76 MHz.
- Upstream main brought LUTRAM/SRL clock-to-out, LUT DI2 checks, falling-edge clock timing and the router2 PerWireData rework.

Still untimed in nextpnr (see `runs/2026-11-10-linuxcal/missed/README.md`): CARRY4 DI->CO/O arcs (never imported), DSP48E1, ISERDES/OSERDES,
IDELAY/ODELAY, MMCM DRP, ICAP, GTX and IO; nextpnr ignores XDC false paths, max delays and clock groups and times no cross-clock path.
The SGMII GTX output clocks have no create_clock in either tool.

## Calibrated delays against silicon and Vivado

- Window measurements (at-speed partial-reconfiguration windows, `runs/2026-11-05-char`, `runs/2026-11-09-cool`, `runs/2026-11-09-npcal`):
  board 1 silicon sits at 0.23 (rise) / 0.37 (fall) of the way from Vivado 2020.1's fast corner to its slow corner, steady with LUT depth;
  silicon is about 0.72 x Vivado slow (rms 109 ps, r 0.995). Calibrated nextpnr sits at 0.15/0.25 and is flat in fanout and length
  (r 0.990 against Vivado over ~24,700 net arcs); stock drifts with depth.
- Vivado needs the route as a DCP: `runs/2026-11-10-linuxcal/dcp-c/j2d` is a patched copy of ~/json_drc-portable's json2dcp that imports
  LUT route-throughs as Vivado records them (diff in `scripts/vc707-timing/json2dcp-rt.diff`); 99.3% of nets come out fully routed.
  `full2json.py` converts nextpnr's himbaechel pip names first. Known converter defect: its LUT logical->physical pin map disagrees with
  the route, so Vivado's per-pin LUT delays cannot be compared yet.

## Board results, Linux harness (VexRiscv RV32GC SoC, 756 RAMB36), build C placement

Board 1 = the VC707 with a working fan (JTAG serial 210203A7E74F), die 38-41 C. Board 2 = a second VC707 whose fan does not work
(210203A7E5A5). Pass = Memtest OK, Linux boots over TFTP/NFS, and the FP test set gives fptest2 x3 af41ac2fe8fa931d, fptest x2
2a2c4ef7aebbddfd, fpeq 0/0/0, fpcmp 3000 sorts 0 violations.

| Route (calibrated chipdb unless stated) | nextpnr sys Fmax | Board 1 | Board 2 |
|---|---|---|---|
| rebcal (seed 1, 4c3652aa) | 70.76 | pass 70.00, 72.17, 73.33, 74.00; **fail 75.00** (Memtest: bus, addr, data errors) | pass 70.00 (die 26-39 C) |
| cal-s2 (seed 2) | 71.64 | pass 72.22, 73.33; **fail 74.00** (Linux boots, hangs in the FP tests) | |
| cal-s3 (seed 3) | 78.00 | pass 76.17; **fail 77.75** (Linux boots, hangs in the FP tests) | |
| cal2fix (pre-RAMB36-fix calibrated route + the OUTMUX line) | 100.23 then | pass 66.67, panic 83.33, Memtest KO 90-100 | |
| stock route, same placement | 61.76 | pass 66.67 | |

m = (last pass .. first fail) / F_cal on board 1 at ~40 C: rebcal 1.046-1.060, seed 2 1.024-1.033, seed 3 **0.977-0.997**. So the
calibrated estimate is within about +-4% of board 1's failing clock route to route, on either side. Seeds 2 and 3 were a blind test of
m = 1.046 from rebcal alone: it put their failure 1-2% and 5% too high. Use **m = 0.97** (just under the lowest seen), which keeps every
route's prediction below its first failure.

## Board to board (`runs/2026-11-11-board2/README.md`)

Window l2 (64 paths, rise), the same build C harness at 66.67 MHz on both boards. Board 2 ran at 52-62 C (mean 58.8), board 1 at 36.8, 40.3
and 48.0 C (the 48 C one held by the fan ECO). Board 2's C-R / board 1's: 0.942 (vs 36.8 C), 0.935 (vs 48.0 C), 0.925 against board 1
extrapolated to 58.8 C along its same-session line. So board 2 is about 6-7.5% faster at equal temperature; the temperature correction
is small (board 1 rise slope ~150 ppm/C within a session, 600-1000 ppm/C upper bound across sessions). After one scale factor the paths
still differ by 23 ps rms between boards, against 4.5-10 ps for a repeat on one board.

Both parts are -2. Binning bounds the slowest legal part by Vivado's -2 slow corner (0.95 V, 85 C). On window 2 board 1 is ~0.72 of
that corner and board 2 ~0.67, so the calibration board is the slower of the two and nearer the bin limit.

## Go/no-go rule

A route will run on board b at clock f if

    f <= F_cal x m x s_b x d_T

- F_cal: calibrated nextpnr's sys-clock Fmax for the route (report.json or the last "Max frequency" line of the log).
- m: board 1's failing clock / F_cal at ~40 C, **0.97** from three routes (range 0.977-1.06; see the table).
- s_b: 1.00 for board 1, ~1.07 for board 2 (window l2 only; whole-route value not measured).
- d_T: 1 - 1000 ppm/C x (T_max - 38 C), the upper-bound slope: 0.97 at 70 C, 0.955 at 85 C.

Board 1 up to 70 C: f <= F_cal x 0.97 x 0.97 = 0.94 x F_cal (rebcal 66.6, seed 2 67.4, seed 3 73.4 MHz). Board 2 adds s_b ~1.07. For a sign-off figure independent of the
board, use Vivado's -2 slow corner on the converted DCP instead.

## How to repeat a board point

All in `runs/2026-11-10-linuxcal/` (copies in `scripts/vc707-timing/`):
1. Route on the i9 (`runs/2026-11-10-rebase/run.sh` or `seeds.sh` as templates; `--seed` for another route on the same placement;
   `-o preplaced=` keeps build C's placement, which `retime.sh` needs because the BIOS ROM is patched in place). Copy `harness.fasm`
   (and `routed.json` for `rtcheck.py`) into `<route>/`.
2. `bash retime.sh <route> M D`: patches the BIOS boot clock (sys = 200 x M / (12 x D) MHz, integer counters only, VCO 600-1440 MHz)
   into the FASM and builds `retime/<route>-mMdD/harness.bit`; BIOS images are reused per M/D.
3. `bash step.sh <route> M,D ...`: `hot.sh` per clock (JTAG load with `console.py`, Linux boot, FP tests through `board.py`, stop at
   80 C on `tlog.sh`'s live XADC log `runs/2026-11-05-char/temp5.csv`), stops at the first failure.
Steps used: 70.00 (21/5), 72.22 (13/3), 73.33 (22/5), 74.07 (40/9), 75.00 (9/2), 76.19 (32/7), 77.78 (14/3), 79.17 (19/4), 80.00 (24/5),
81.48 (44/9), 83.33 (5/1).

Board traps:
- ttyUSB numbering differs between the boards and with plug order (board 2: CP2103 on ttyUSB2). `trial.sh` exports
  `CONSOLE=/dev/serial/by-id/usb-Silicon_Labs_CP2103_...` and `board.py` reads `CONSOLE` (default ttyUSB0); `console.py` takes the
  port as its 5th argument.
- The BIOS is built for 100 MHz (tCK taps 32 in leveling); other clocks work but the leveling assumption is off.
- `yrun20.sh NOWAIT=1` skips the temperature-level wait for window sweeps; `stopb2.py` stops a sweep and powers Linux off.
- Never write BPI flash; JTAG only. Kill jobs by PID, never by a pattern your own command line contains.

## Open items

- More routes (other placements, other designs) to tighten m; three routes on one placement give 0.977-1.06.
- s_b for board 2 on a whole route (board 2 only fails at a hotter temperature without its fan; needs external airflow to match).
- Re-time existing routes: nextpnr cannot reload its own xilinx routed JSON (NEXTPNR_BEL and ROUTING are written in nextpnr-xilinx site
  form by `postRouteArchInfo`, `attributesToArchInfo` reads only himbaechel names).
- CARRY4 DI arcs, the warning for arcs dropped by a missing clock port, and the converter's LUT pin map.
- Rebuild the published calibrated chipdb (pre-release 2 predates the RAMB36 fix).
