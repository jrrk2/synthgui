# vc707_calc sources

Copied from vc707-openflow-demos at commit 29eab2e (`uartram/`, the `make calc`
example) so that `projects/vc707_calc.json` runs without that repository;
flattened into one directory.  Each file keeps its own licence header.

A UART calculator at 115200 8N1: type `355*113=` and it answers `40115`.  An
8-bit accumulator CPU runs the program in `calc_init.svh` out of a 2 KB block
RAM and multiplies on an explicitly instantiated DSP48E1.  Every multiply is
also done in software and the two compared, and a mismatch is marked with `?`.
`python3 asm.py` assembles the program, runs its tests on an ISA simulator, and
with `--emit` rewrites `calc_init.svh`.

| here | from |
|---|---|
| top_min.sv | uartram/top_min.sv |
| calc_core.sv | uartram/calc_core.sv |
| calc_init.svh | uartram/calc_init.svh |
| byte_fifo.sv | uartram/byte_fifo.sv |
| lfsr_div.sv | uartram/lfsr_div.sv |
| uart_rx_lfsr.sv | uartram/uart_rx_lfsr.sv |
| uart_transmitter.sv | uartram/uart_src/uart_transmitter.sv |
| slib_input_sync.sv | uartram/uart_src/slib_input_sync.sv |
| top_min.xdc | uartram/top_min.xdc |
| asm.py | uartram/asm.py |

Differences from the original build:

- The clock is the 200 MHz SYSCLK (`top_min.xdc`), not the 156.25 MHz
  USER_CLOCK (`top_min_uc.xdc`, `USE_USERCLK`).  USER_CLOCK is on a left-side HP
  bank (LIOB18), and nextpnr has no FASM key for a differential input there.
  The old flow only used USER_CLOCK because it could not reach 200 MHz.
- `xil_bb.v` is not needed: the project's Xilinx cell models declare the
  primitives, and DSP48E1 is in the black-box list.
- `patch_rx_iob.py` (a frame patch for the RX input on AU33) is not applied.
  The OCaml REPL takes typed input on that pin through this flow, so the
  database it uses should not need it.

On the VC707 (2026-10-21) it answers `12+34=46`, `355000000/113=3141592` and
`9/0=E` at 200 MHz, and multiplies on the DSP48E1 `355*113=40115`,
`65535*65535=4294836225` and `123*456=56088` with no `?` (DSP and software
agree).  nextpnr reports 279 MHz; OpenSTA on the same SDF finds a
15-LUT path from the RX FIFO to the accumulator at about 142 MHz.
