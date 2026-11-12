# vortex_vc707 memory images and generated headers

`projects/vortex_vc707.json` builds the Vortex GPGPU (https://github.com/vortexgpgpu/vortex)
standalone on the VC707: one core, 4 warps, 4 threads, integer only
(`VX_CFG_EXT_F_DISABLE`), 50 MHz, with 256 KB of block RAM as device memory, a
DCR launch sequencer in place of the host and the LEDs as the only output.
LED[6:0] show the low bits of the last word the kernel stored to the LED
register; LED7 is the core's busy flag, which stays on because the kernel
never finishes.

The RTL, the board top, the clock generator and the pin constraints stay in the
Vortex checkout at `~/vortex`: https://github.com/jrrk2/vortex, branch
`rom_update`, commit 375fb0301 (`hw/syn/xilinx/vc707/`; the RTL is unchanged
from the earlier `vc707-synthgui` 06832e0a8, the later commit only adds the
kernel-update script).

This directory holds what that repository does not:

- `lane00.hex` .. `lane63.hex`, the 64 byte-lane images the synth step reads
  through `MEM_INIT_DIR`: the kernel `hw/syn/xilinx/vc707/blink.S` (a counter
  whose top bits are stored to the LED register at 0xFF00) placed at
  0x80000000, split into 64-byte lines, one byte per lane, 4096 lines deep.
- `vxgen/`, the headers Vortex's `configure` generates (`build/hw/VX_config.vh`,
  `VX_types.vh`, `vortex_opae.vh` and `build/sw/*.h`, from
  `../configure --xlen=32`).  The project's include path names this copy, so the
  checkout needs no configure step and every host synthesises from the same
  headers.

Regenerate the lane images after changing the kernel with

    cd ~/vortex/build/hw/syn/xilinx/vc707 && make mem
    cp mem/lane*.hex ~/synthgui/projects/vortex_vc707-src/

## Results

First result (2026-10-25, Apple silicon, yosys-era tools): synth 15 min, place
& route 3 h 57 min, 136 k LUTs, 64 k flops, 241 RAMB36, 59 DSP, routed Fmax
53.6 MHz; the bitstream ran on the board with the LEDs counting.  On 29 Oct
with the Verilator synthesis: 110,725 LUTs, router2 71 iterations in 16,729 s,
57.5 MHz.

2026-11-11 (run A2 on the i9, runs/2026-11-11-vortex), reproducible from this
branch's submodule pins and `scripts/build-deps.sh`:

| | |
|---|---|
| synthesis | Verilator 8ac1a4992 (deps/verilator), 21 s: 171,441 cells, 99,083 LUTs, 63,419 FFs, 6,815 RAM64X1D, 1,416 CARRY4, 417 MUXF7, 241 RAMB36 (23 initialised), 37 DSP48E1 |
| chipdb | the calibrated xc7vx485t one, `{builds}/nextpnr/chipdb-xc7vx485t-cal.bin` (build-deps makes it from prjxray-db's `virtex7/timings/silicon/xc7vx485t-2.cal.json`) |
| place and route | nextpnr routethru (the 60 ps block RAM clock pin; the earlier 430 ps wedged the hold-fix reroute), 79 min in all: router2 26 iterations in 1,351 s, hold-fix 13 buffers in 40 s |
| timing | routed Fmax 83.16 MHz against the 50 MHz the MMCM makes; OpenSTA on the SDF agrees |
| board | VC707 board 1 over JTAG, 2026-11-12: LED[6:0] count, LED7 on (busy).  A functional pass at 50 MHz, not a timing limit |
