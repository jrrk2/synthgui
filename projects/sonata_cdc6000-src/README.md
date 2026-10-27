# cdc6000 on the Sonata (trial)

The CDC 6000 core of `../cdc6000-src` (the simple one, `cdc6000_core.sv`: one state machine, one synchronous memory;
not the scoreboarded `cdc6000_sb.sv`) on the Sonata's xc7a50t, running the 1972 Pascal compiler as on the VC707.

| here | change from the VC707 build |
|---|---|
| `sonata_cdc_top.v` | `vc707_cdc_top.v` with the 25 MHz board clock used directly (no IBUFDS or MMCM), `nrst` as the reset button, Sonata pins, and `MEM_AW(15)`: 32K words instead of 128K |
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

## Place and route: open

The first attempt (pnr options as the small Sonata projects have them: no congestion spreading) placed with an
estimate of 14.36 MHz against the 25 MHz target and then routed with the overuse hovering at 22 to 43 wires from
iteration 29 to 43, not converging. (synthgui itself then crashed on that Windows PC, with nextpnr still routing; not
reproduced.) The likely hot spot is the memory: 60 block RAMs in 32K x 1 mode each take all 15 address bits, so the
address register drives about 900 BRAM pins in the BRAM columns.

The options are now those of the VC707 cdc6000 build: `pnr.cong_spread` (push cells out of congested regions) and
`pnr.tmg_ripup` added. Not yet run with them. If the router still does not converge, next steps:

1. duplicate the memory's address register per group of block RAMs (keep the copies from being merged), so no one
   register drives all 900 address pins;
2. if 25 MHz is not met (the -1 Artix-7 is slower than the VC707's -2 Virtex-7), run the core at 12.5 MHz with an
   MMCM, and set `CLK_MHZ` to match so the UART divisor stays right.

The memory could also go outside the core with `EXT_MEM` (one synchronous port, data the cycle after), but that is
still block RAM: HyperRAM or flash would need the core to take wait states.
