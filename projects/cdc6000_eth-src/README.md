# cdc6000 with Ethernet: the shell, NFS and the RAM disk

The CDC 6000 core (`cdc6000_core`, or the dual-issue `cdc6000_sb` with
`CORE_SB=1`) with the VC707's SGMII Ethernet, copied from cdc6000 at commit
a6a5700 (`fpga/vc707-eth`, `fpga/eth-rtl`, `rtl`) so that
`projects/vc707_cdc_eth.json` runs without that repository.  The core runs the
1972 Pascal compiler under a shell on the UART (115200 8N1, plain text:
`help`, `dir`, `compile name`, `run`, `ram`), and reaches its files through
NFS over UDP: the server 192.168.1.106 and the export `/srv/nfs/vc707/cdc`
(constants in the repository's `nfs/nfslib.pas`); the board takes its own
address by DHCP and prints it in the banner.  `ram`
switches to a 1 MB RAM disk in block RAM that holds the compiler's source
and image.

Synthesised by Verilator directly from the SystemVerilog: the repository's
open flow (`fpga/vc707-eth/openflow.sh`) needed sv2v to get the cores past
yosys, this one does not.

The core's clock is 25 MHz (`SYS_DIV=40.000`, `CLK_HZ=25000000` in the
project), as in the batch build (`projects/cdc6000.json`).  The repository's
top asks for 50 MHz, which its Vivado build meets; nextpnr reaches about
23 MHz on this netlist, and at 50 MHz the timing-driven rip-up
(`pnr.tmg_ripup`, left off here) runs the router for hours without closing.

| here | from |
|---|---|
| cdc_pkg.sv, cdc6000_core.sv, cdc6000_sb.sv | rtl/ |
| vc707_cdc_eth.v, cdc_eth_core.v, vc707_cdc_nextpnr.xdc | fpga/vc707-eth/ |
| simpleuart.v, liteeth_sgmii_phy.v, eth_*.sv, axis_gmii_*.sv, rgmii_lfsr.sv, sgmii_soc_liteeth.sv, clkgen_vc707.sv | fpga/eth-rtl/ |
| cdc_ram_bram.v, cdc_disk_bram.v, pascimg, pascal.pas | generated: `make images` |

`cdc_ram_bram.v` (the memory: the shell run time, the compiler and the NFS
driver, as 120 RAMB36E1) and `cdc_disk_bram.v` (the RAM disk, 256 RAMB36E1)
are written by the repository's `mkimage_shell.sh`.  They are Verilog-2001
and name a port `do`, a SystemVerilog keyword, so `make images` wraps them in
`` `begin_keywords "1364-2005" ``.

    make -C projects/cdc6000_eth-src images    # regenerate the images (CDC= the repository)
    make -C projects/cdc6000_eth-src export    # pascimg and pascal.pas into the NFS export
    make -C projects/cdc6000_eth-src selfhost  # program the board, `compile pascal` over NFS, check the fixed point

`selfhost` deletes the export's `pascal.cdc` first, so a pass comes only from
this compile.  The compiler's object code must equal the emulator's
(`host/run/pasclgo.out`) and rebuild `pascimg`, the compiler that ran.  Close
any terminal on the console port first: `cdcshell.py` opens it exclusively.

Measured 2026-10-22 (nextpnr clock-tree-bram-place, Verilator synthesis):
clk_sys 22.69 MHz against 25 MHz, the Ethernet clocks pass at 125 MHz; LVS
40455 proved, 0 differ, 0 unknown; DHCP, NFS and the self-compile (about
37 s) work on the board, and the output is the self-hosting fixed point.
