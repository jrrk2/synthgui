# legend64 on the VC707 (xc7vx485tffg1761-2)

legend64 is a 64-bit RISC-V core (RV64GC, Sv39, M/S/U) written for this board, in a SoC with
1 GiB of DDR3 through a LiteDRAM core, SGMII Ethernet, a 16550 UART, a PLIC and a window onto
the BPI flash. It boots Debian from an NFS root. This directory is a copy of what the project
reads, written by `synthgui/make_project.py --package` in the legend64 repository; change the
design there, not here.

| File | What it is |
|---|---|
| `legend64*.sv`, `legend_*.sv`, `litedram_line_adapter.sv` | the core, the SoC and the board top (`legend64_vc707`) |
| `litedram_core_open.v` | the generated DDR3 core, with the PLL's `COMPENSATION` stated for nextpnr |
| `axis_gmii_tx.sv` | verilog-ethernet's transmitter with one correction; the rest of the MAC and the SGMII PHY come from `vc707_ethmin-src` |
| `boot.hex` | the boot monitor: DDR3 initialisation and memory test, then TFTP boot, a UDP loader and flash update |
| `legend64_vc707_open.xdc` | pins and clocks for nextpnr |
| `legend64_vc707_synth.sdc` | the clocks for the mapper's timing-driven passes |
| `mapper-patches/` | fixes to the mapper this design needs (below) |

## Building

The core clock is 25 MHz (`SYS_DIV`, `CLK_HZ` and the two constraint files say so; the
legend64 repository's script writes all of them for another clock). The mapper runs two
timing-driven passes with a fanout limit of 32 and puts the deep memories in x2/x4 block RAMs.

The mapper must have the fixes in `mapper-patches/` (jrrk2/verilator `synthesis` at c27d3c4
plus these ten; synthgui 0.1.4 pins a verilator that has them). Without 0005 the fetch buffer is
mapped wrongly and the core is silent; without 0008 the fanout limit inverts the reset of most
of the SoC, and the bitstream configures with its clock and Ethernet link alive and nothing
else. 0009 is the x2/x4 block RAM option this project uses, 0010 optional register retiming,
which it does not. The legend64 repository has the tests (`synthgui/patches/tests`,
`synthgui/netlist_compare.py`).

How fast it goes, measured on one VC707 at room temperature:

| Flow | Result |
|---|---|
| this project as it is (nextpnr's own database) | 27 MHz routed against the 25 MHz clock |
| nextpnr with the silicon-calibrated database (Place and route > Chip database), 33.3 MHz clock, router timing rip-up and alternate weights | 38.6-40.5 MHz routed (typical); Debian on the board |
| that route reclocked with `scripts/mmcm_retime.py` | runs Debian up to 40.0 MHz, not at 41.7 |
| the same routes by Vivado's slow corner (json_drc-portable `tools/`) | 27-29 MHz: what holds across parts, voltage and temperature |
| this netlist placed and routed by Vivado alone | 50 MHz with +0.3 ns, Debian on the board |

At a 40 MHz clock nextpnr does not close (35 MHz without the router's timing rip-up, no
convergence with it), so a faster clock is best had by routing at 33.3 MHz and reclocking.

`RECONFIG=0` leaves the ICAPE2 block out, which the open flow does not place; `reboot` under
Linux therefore does not reload the FPGA as it does in the Vivado build.

## On the board

Loaded over JTAG, the monitor prints its banner on the UART (115200), initialises the DDR3
and answers at 192.168.1.51. It then fetches `legend64/fw_jump.bin`, `legend64/Image` and
`legend64/legend64-vc707.dtb` by TFTP from 192.168.1.176 and starts OpenSBI. The device tree
must be built for the core clock (`TIMEBASE_HZ=25000000`). LEDs: 7 heartbeat from the core
clock, 6 DDR3 ready (set by the monitor), 5 SGMII link.

Proven on a VC707 on 2026-11-21: Debian from NFS with SSH, both flash partitions seen by the
kernel, floating point checked against a host, 8 MiB through the Ethernet receive FIFO intact.

Apache-2.0, see `LICENSE`.
