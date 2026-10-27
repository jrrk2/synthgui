# cdc6000 on the Sonata

The CDC 6000 core of `../cdc6000-src` (the simple one, `cdc6000_core.sv`: one state machine, one synchronous memory;
not the scoreboarded `cdc6000_sb.sv`) on the Sonata's xc7a50t, running the 1972 Pascal compiler as on the VC707.

| here | change from the VC707 build |
|---|---|
| `sonata_cdc_top.v` | `vc707_cdc_top.v` with the 25 MHz board clock (no IBUFDS) turned into 12.5 MHz by an MMCM (`CLK_KHZ`, 12500; the UART divisor follows it), `nrst` as the reset button, Sonata pins, and `MEM_AW(15)`: 32K words instead of 128K |
| `mem.hex` | `../cdc6000-src/mem.hex` with the stack limit (word 3) lowered from 0x1FF00 to 0x7F00, so an overflow is reported instead of wrapping in the smaller memory |
| `top.xdc` | clock P15, reset T5, UART C17 (tx) / D18 (rx) as `sonata_romlinux` and `sonata_telegraph` use them, user LEDs |

## Why 32K words is enough

The compiler touches far less than the 128K the VC707 design has. Measured with the cdc6000 repository's emulator
(`host/cdcemu.c`, instrumented to mark every word fetched, read or written):

| workload | instructions | highest word touched | words touched |
|---|---|---|---|
| hello.pas | 18 980 | 18 606 (044256B) | 2 236 |
| self-compile (pascal.cdc) | 34 799 506 (the board's count) | 19 134 (045276B) | 11 809 |

The image itself ends at word 18 442. 32K words leaves about 13K words of headroom.

## Fit (synthesis on Windows, 2026-10-27)

| resource | VC707 cdc6000 | this design | xc7a50t has |
|---|---|---|---|
| LUTs (synthesis) | 14 749 | 14 479 | 32 600 |
| SLICE_LUTX (nextpnr) | | 22 929 (35 %) | 65 200 |
| flip-flops | 2 084 | 2 080 | 65 200 |
| CARRY4 | 1 333 | 1 363 | 8 150 |
| DSP48E1 | 16 | 16 | 120 |
| RAMB36E1 | 242 | **62 (82 %)** | 75 |

## Place and route

At 25 MHz it does not work. Without congestion spreading the router did not converge; with the VC707 build's options
(`pnr.cong_spread`, `pnr.tmg_ripup`) it converges (overuse 0 from iteration 21) but about 5 500 arcs still fail timing, and
the placer estimates 15.9 MHz. So the core runs at 12.5 MHz: the board's 25 MHz clock x 24 = 600 MHz in an MMCM, divided
by 48 (`CLK_KHZ`). nextpnr then reports 15.89 MHz against the 12.5 MHz target (PASS), and the whole flow, synthesis to
bitstream, takes 11 minutes 45 seconds on an 8-core iMac (place and route 158 s).

## On the board

Loaded over JTAG only (`openFPGALoader -c ft4232`), with `../cdc6000-src/cdcrun.py` on the USB UART at 921600 baud:

| program | instructions | cycles | result |
|---|---|---|---|
| hello.pas | 18 980 | 2 637 368 | listing and the two binary files, fault 0 |
| the compiler's own source (pascal.cdc) | 34 799 506 | 91 985 566 (7.4 s) | fault 0; `pasclgo.out` (12 653 words) and `pmdfile.out` (808) equal the emulator's, word for word |

The instruction counts are the emulator's. The self-hosting fixed point holds except for word 3, the stack limit, which
the compiler rebuilt from the board's output sets back to the default 0377400: run
`selfhost_check.py mem.hex BOARD EMU RUNTIME_IMG PARMLIST NEXT_IMG 3` (the cdc6000-src Makefile's `selfhost` rule, with `3`
added) for the check to leave that word out. An actual stack overflow, which the lowered limit should report, has not been tried.

Not tried: a power cycle from the flash (nothing was written to it).
