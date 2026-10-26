# vortex_vc707 memory images

`projects/vortex_vc707.json` builds the Vortex GPGPU (https://github.com/vortexgpgpu/vortex)
standalone on the VC707: one core, 4 warps, 4 threads, integer only
(`VX_CFG_EXT_F_DISABLE`), 50 MHz, with 256 KB of block RAM as device memory, a
DCR launch sequencer in place of the host and the LEDs as the only output.
The RTL, the board top, the clock generator and the pin constraints stay in the
Vortex checkout at `~/vortex`, on its `vc707-synthgui` branch
(`hw/syn/xilinx/vc707/`, commit 06832e0a8).  That checkout must be configured
(`cd ~/vortex/build && ../configure --xlen=32 ...`), because the generated
`build/hw/VX_config.vh`, `build/hw/VX_types.vh` and `build/sw/VX_config.h`
are on the include path.

This directory holds only what that repository does not: the 64 byte-lane
images `lane00.hex` .. `lane63.hex` the synth step reads through
`MEM_INIT_DIR`.  They are the kernel `hw/syn/xilinx/vc707/blink.S` (a counter
whose top bits are stored to the LED register at 0xFF00) placed at 0x80000000,
split into 64-byte lines, one byte per lane, 4096 lines deep.

Regenerate them after changing the kernel with

    cd ~/vortex/build/hw/syn/xilinx/vc707 && make mem
    cp mem/lane*.hex ~/synthgui/projects/vortex_vc707-src/

The same Makefile's `make project` writes an equivalent project file with
absolute paths into the build directory; this copy is the one with `~` and
`{root}` paths that runs from any checkout location.

First result (2026-10-25, Apple silicon): synth 15 min, place & route 3 h 57 min,
136 k LUTs, 64 k flops, 241 RAMB36, 59 DSP, routed Fmax 53.6 MHz; the
bitstream ran on the board with the LEDs counting.
