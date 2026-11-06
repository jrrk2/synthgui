# RV32GC on the VC707: routing and loading its own fabric

`projects/vc707_rv32gc_fast.json` is a VexRiscv RV32GC Linux SoC, synthesised by the Verilator mapper and placed and routed by
nextpnr, that runs nextpnr on itself and loads the result into its own fabric through the ICAP while Linux keeps running.
Everything on the board is native code; there is no interpreter.

Partial reconfiguration itself is described in nextpnr's `docs/xilinx-partial-reconfiguration.md`.

## The design

| | |
|---|---|
| CPU | VexRiscv SMP, 1 core, FPU, RVC |
| I cache | 32 KB, 8 ways |
| D cache | 32 KB, 8 ways |
| TLBs | instruction 16, data 64 |
| L2 | 512 KB (756 RAMB36 in all, 29286 LUT, 23728 FF) |
| Clock | 77.75 MHz, set by the BIOS at boot: 200 MHz x 14 / (12 x 3) |
| Kernel, root | TFTP (`mknetboot.py`), NFS; `kernel/fpu-nfs.config` includes /dev/mem for `atctl` |

The BIOS clock is a compile-time constant: `BOOT_MMCM=14,3 python3 vc707_atspeed_fpu.py ...`. The device tree must agree:
`mknetboot.py --sys-clk`. With a different value there, Linux's clock is scaled: it then counts cycles at the stated rate, which
is how the cycle counts below were taken.

## Requirements

The project needs the mapper fix below in `build-deps/prefix` (`scripts/build-deps.sh`, or `make install` in
`build-deps/verilator`). An older mapper silently produces wrong floating point.

The harness is `at_block` as a black box, so build it with `xc7/pr_flow.sh merge` and `harness` rather than the project's own P&R
step, pinning the test MMCM: `PINS="tmmcm=X305Y43/MMCME2_ADV_X0Y0.MMCME2_ADV"`.

## The loop

    host, once per harness   pr-partial prep -> minidb/, row.txt (13 MB of database, the window's frame row only)
    host, per circuit        at-gen + pr-block-json window -> window.json, reserve.txt
    board                    tools/atctl/selfmod.sh: nextpnr -> fasm2frames -> pr-partial extract --row -> atctl icap
    board                    tools/atctl/atsweep.sh: capture-phase sweep

The tools build for the board with `tools/build-standalone.sh` (`CXX=` the RV32 compiler) and `tools/atctl/build.sh`. Measured on
the base CPU: route 978 s, frames and image 37 s, ICAP load 0.33 s; the image is byte-identical to the host's, and the route's FASM is
identical to x86 with the same `--threads 1 --seed 1` apart from its version comment.

Still on the host: generating the circuit's netlist and `prep`, both now C++ that could move to the board. The window has only
clocks and test controls, so a useful peripheral needs a bus interface, a decoupler and a driver.

## Choosing the CPU

Benchmark: one route of a 463-cell window, FASM identical in every run.

| Build | I cache | D cache | iTLB, dTLB | L2 | nextpnr Fmax | Runs at | Cycles | Real time | Against base |
|---|---|---|---|---|---|---|---|---|---|
| Base | 4K, 1 way | 4K, 1 way | 4, 4 | 128K | 79.06 | 83.3 | 79.2 G | 951 s | 1x |
| A | 32K, 8 | 16K, 4 | 16, 32 | 128K | 76.38 | 77.75 | 24-26 G | 310-337 s | 2.8-3.1x |
| B = A + `dynamic_target` prediction | 32K, 8 | 16K, 4 | 16, 32 | 128K | 70.68 | not run | | | |
| **C** | **32K, 8** | **32K, 8** | **16, 64** | **512K** | **82.85** | **77.75** | **20-22 G** | **261-284 s** | **3.4-3.6x** |

Each pair of times is a first run and a repeat; the repeat gains from the file cache. C gave correct results on these tests at 77.78, 79.17, 80.56, 81.25 and 81.48 MHz at a die temperature of about 41 C, the last with two benchmark
routes in 252-273 s (FASM identical), and panics at boot at 83.33. That is functional testing of one part: it shows typical behaviour on the paths the
tests happen to exercise, not worst-case timing, so it does not establish a safe clock. A is correct at 66.7, 72.2 and 77.75 and wrong at 79.17: wrong hashes that
change from run to run, which is timing. Multiplier 9, divider 2 (75 MHz) hangs at `/sbin/init` on A, not understood.

### Simulator

`tools/vexcache/`: a TCG plugin models many memory systems in one run of `qemu-riscv32` (user mode, `--enable-plugins`). Round-robin
ways and TLB entries as VexRiscv has them; write-through D cache; direct-mapped L2. `membench.c` measures the penalties on the board;
`model.py` fits the base cost per instruction to one measured time. Kernel activity is not seen, and counters are not thread-safe
(about 0.02% between models).

The benchmark is 9.05 G instructions, 2.54 G loads, 0.82 G stores.

| Data TLB entries | 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 |
|---|---|---|---|---|---|---|---|---|
| Misses, G | 0.87 | 0.58 | 0.36 | 0.18 | 0.058 | 0.016 | 0.006 | 0.002 |

| Instruction TLB entries | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|
| Misses, G | 0.13 | 0.077 | 0.034 | 0.018 | 0.0015 | 0.00001 |

Instruction TLB size is worth 1-2% in the model; the data TLB is the one that matters, and past 64 entries it gains almost nothing.

The model ranks well and undershoots: it predicted 1.74-2.09x for A's cycles against 3.03x measured. Use it to choose, not to promise.

Penalties at 83.3 MHz on the base build: L1 hit about 4 cycles, L1 miss hitting L2 about 48 more, L2 miss about 85 more, TLB walk 13-26.
Taken jump 5.6 cycles within a line and about 13 across, load-use 2.2, plain instruction 1.1.

### Branch prediction

Not exposed by LiteX: the generator has `prediction = NONE`. `tools/vexcache/{vexriscv,litex}-prediction.patch` add it. Rejected: branches
account for about 71 s of 951, a 512-entry predictor mispredicts roughly 12-19% in the model, and B lost 7.5% of Fmax against A. B was
not measured on the board, so this rests on the estimate.

## Finding faults: the lockstep simulator

`tools/lockstep/`: RTL and mapped netlist as two Verilated models on one memory, answering the RTL's bus, stopping at the first differing
output. `vcdcmp.py` and `vcdshow.py` find the first differing register by name. `gatecells.v` counts reads of an address being written
with a writer that is not READ_FIRST, and returns inverted data, so a dependence on it shows.

It found the floating-point fault that sat under all of the above: the mapper put one write and two independent reads on one block RAM's
two ports, losing a read in every write cycle. A first copy of a reproducer did not fail. It needs the failing binary's exact instruction
sequence (`fpeq_bare.cc`, from the disassembly), because the fault depends on writeback timing.

## Open

- The D cache maps with NO_CHANGE on both ports. A same-address read during a write is, as far as remembered from UG473, undefined on silicon.
  Nothing shows it mattering, and READ_FIRST would remove the question.
- The mapper's fix gives LiteEth's `mac_sram_reader` 8 block RAMs it does not need: its read shares the write address, but the check compares
  source text. Correct, wasteful.
- The `sv-tests` sweep shows no change from the mapper's fixes (652 tests, output byte-identical), but no test maps to a block RAM. Directed RAM tests in
  `runs/2026-11-05-mapfix/` confirm them; the fixes leave this design's mapping byte-identical. They are committed and installed, and no RAM form they change has been on silicon.
- Real timing, in place of nextpnr's estimate: planned, next on the board.
