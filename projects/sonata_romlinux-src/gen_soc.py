#!/usr/bin/env python3
"""LiteX SoC for the lowRISC Sonata board: VexRiscv-SMP (Linux variant) with its ROM and RAM outside the FPGA.

    L=<litex-deps>   (migen, litex, litespi and pythondata-cpu-vexriscv-smp on PYTHONPATH)
    PYTHONPATH=$L/migen:$L/litex:$L/litespi:$L/pythondata-cpu-vexriscv-smp python3.12 gen_soc.py --output-dir build

  ROM  0x02000000  W25Q256 quad SPI flash on the appspi pins, read in place (litespi memory map).
  RAM  0x40000000  8 MB W956 HyperRAM, through LiteX's 4:1 SDR HyperRAM core (fabric flops and tri-states
                   only, so the open flow can place it; the same core as projects/sonata-lib/hyperram.v).
  A small boot ROM (the BIOS) and 6 KB of SRAM stay in block RAM.

Derived from the lowRISC Sonata LiteX target (litex-boards lowrisc_sonata, jrrk2/sonata-linux) with the Vivado
specifics removed: no ODDR/IDDR, no 2x clock, no JTAG TAP. Added: the KSZ8851 SPI Ethernet, DIP switches,
and the LCD text console.  The system clock is 50 MHz, which
keeps the sonata-linux device tree (50 MHz timebase), kernel and flash image usable unchanged; the HyperRAM
clock is therefore 12.5 MHz.
"""
import os

from migen import *
from litex.gen import *

from litex.build.generic_platform import Pins, IOStandard, Subsignal, Misc
from litex.build.xilinx import Xilinx7SeriesPlatform

from litex.soc.cores.clock import S7MMCM
from litex.soc.cores.led import LedChaser
from litex.soc.cores.hyperbus import HyperRAM
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder import Builder
from litex.soc.interconnect import wishbone

_io = [
    ("clk25", 0, Pins("P15"), IOStandard("LVCMOS33")),
    ("nrst",  0, Pins("T5"),  IOStandard("LVCMOS33")),     # PCB >= 0.3; R11 for <= 0.2

    ("serial", 0,
        Subsignal("tx", Pins("C17")),
        Subsignal("rx", Pins("D18")),
        IOStandard("LVCMOS33"),
    ),

    # The application flash.  clk is an ordinary pin here, so litespi drives it from a flop.
    ("spiflash4x", 0,
        Subsignal("cs_n", Pins("D10")),
        Subsignal("clk",  Pins("A8")),
        Subsignal("dq",   Pins("C11 C10 A10 A9")),
        IOStandard("LVCMOS33"),
    ),

    # HyperRAM, W956D8MBYA: 1.8 V, differential clock.
    ("hyperram", 0,
        Subsignal("dq",    Pins("B1 E2 H1 A1 E1 B2 C1 D2")),
        Subsignal("rwds",  Pins("F1")),
        Subsignal("cs_n",  Pins("J2")),
        Subsignal("rst_n", Pins("C2")),
        Subsignal("clk_p", Pins("H2")),
        Subsignal("clk_n", Pins("G2")),
        IOStandard("LVCMOS18"),
    ),

    # KSZ8851SNL Ethernet MAC on SPI (1.8 V bank).
    ("spi_eth", 0,
        Subsignal("clk",  Pins("E3")),
        Subsignal("mosi", Pins("D5")),
        Subsignal("miso", Pins("D4")),
        Subsignal("cs_n", Pins("H5")),
        IOStandard("LVCMOS18"),
    ),
    ("eth_rst_n", 0, Pins("J5"), IOStandard("LVCMOS18")),
    ("lcd", 0,
        Subsignal("rst",       Pins("R6")),
        Subsignal("dc",        Pins("U4")),
        Subsignal("copi",      Pins("R3")),
        Subsignal("clk",       Pins("R5")),
        Subsignal("cs",        Pins("P5")),
        Subsignal("backlight", Pins("N5")),
        IOStandard("LVCMOS33")),
    ("user_sw", 0, Pins("D12 D13 B16 B17 A15 A16 A13 A14"), IOStandard("LVCMOS33"), Misc("PULLTYPE=PULLUP")),
] + [("user_led", i, Pins(p), IOStandard("LVCMOS33"))
     for i, p in enumerate("B13 B14 C12 B12 B11 A11 F13 F14".split())]


class Platform(Xilinx7SeriesPlatform):
    default_clk_name   = "clk25"
    default_clk_period = 1e9 / 25e6

    def __init__(self, toolchain="vivado"):
        Xilinx7SeriesPlatform.__init__(self, "xc7a50tcsg324-1", _io, [], toolchain=toolchain)

    def get_verilog(self, *args, special_overrides=dict(), **kwargs):
        # SDRInput as a plain flop (FDCE), not an IDDR with its second output unused.
        from litex.build.io import SDRInput
        from litex.build.xilinx.common import XilinxSDRInputUS
        so = dict(special_overrides)
        so[SDRInput] = XilinxSDRInputUS
        return Xilinx7SeriesPlatform.get_verilog(self, *args, special_overrides=so, **kwargs)


class SPIHost(LiteXModule):
    """The OpenTitan-derived Wishbone SPI host (rtl/spi_wb.sv, from jrrk2/litex-boards) -- 8 KB of registers
    and transmit/receive buffers; the SystemVerilog is part of the project's sources."""
    def __init__(self, pads):
        from types import SimpleNamespace
        self.bus = wishbone.Interface(data_width=32, adr_width=11)
        irq = Signal()
        self.ev = SimpleNamespace(irq=irq)          # LiteX's IRQ system wants module.ev.irq
        self.specials += Instance("spi_wb",
            p_CSWidth=1, p_BufDepth=2048,
            i_clk_i=ClockSignal(), i_rst_i=ResetSignal(),
            i_wb_adr_i=Cat(Signal(2, reset=0), self.bus.adr),
            i_wb_dat_i=self.bus.dat_w, o_wb_dat_o=self.bus.dat_r,
            i_wb_sel_i=self.bus.sel, i_wb_we_i=self.bus.we,
            i_wb_cyc_i=self.bus.cyc, i_wb_stb_i=self.bus.stb, o_wb_ack_o=self.bus.ack,
            o_irq_o=irq,
            o_spi_clk_o=pads.clk, o_spi_copi_o=pads.mosi, i_spi_cipo_i=pads.miso, o_spi_cs_o=pads.cs_n)


class LCDText(LiteXModule):
    """The 160x128 ST7735 LCD as a 20x16 text console (rtl/lcd_text.v): a write-only Wishbone window onto the
    character RAM (byte at row*20+col, bit 7 = yellow, row 0 = white title) and, at byte offset 0x140, the
    hardware scroll register for rows 1..15."""
    def __init__(self, pads, sys_clk_freq):
        self.bus = wishbone.Interface(data_width=32, adr_width=7)
        wr = Signal()
        self.comb += [wr.eq(self.bus.cyc & self.bus.stb & self.bus.we & ~self.bus.ack), self.bus.dat_r.eq(0)]
        self.sync += self.bus.ack.eq(self.bus.cyc & self.bus.stb & ~self.bus.ack)
        self.specials += Instance("lcd_text",
            p_CLK_HZ=int(sys_clk_freq),
            i_clk=ClockSignal(), i_rst=ResetSignal(),
            i_wr=wr, i_wa=self.bus.adr, i_wd=self.bus.dat_w, i_wsel=self.bus.sel,
            o_lcd_rst=pads.rst, o_lcd_dc=pads.dc, o_lcd_copi=pads.copi, o_lcd_clk=pads.clk,
            o_lcd_cs=pads.cs, o_lcd_backlight=pads.backlight)


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()
        clk25 = Signal()
        self.specials += Instance("IBUF", i_I=platform.request("clk25"), o_O=clk25)
        nrst = Signal()
        self.specials += Instance("IBUF", i_I=platform.request("nrst"), o_O=nrst)
        self.pll = pll = S7MMCM(speedgrade=-1)
        self.comb += pll.reset.eq(~nrst | self.rst)
        pll.register_clkin(clk25, 25e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq)


class HyperRAMGuard(LiteXModule):
    """Keeps every HyperRAM transaction inside the device's 4 us tCSM.

    The LiteX core never closes a burst by itself: it keeps chip select low for as long as the next request is
    the adjacent address (including untagged reads, "for VexRiscv-SMP").  Here a transaction ends after at most
    `max_burst` words, or on any beat that is not a tagged incrementing one, and the next request is held until
    the chip select has been seen high for `gap` cycles.  The last beat of a burst must carry cti=7.
    """
    def __init__(self, bus_in, bus_out, cs_n, max_burst=16, gap=4):
        count = Signal(8)
        hold  = Signal()          # waiting for chip select to rise
        quiet = Signal(4)
        last  = Signal()

        self.comb += [
            bus_out.adr.eq(bus_in.adr), bus_out.dat_w.eq(bus_in.dat_w), bus_out.sel.eq(bus_in.sel),
            bus_out.we.eq(bus_in.we), bus_out.cti.eq(bus_in.cti), bus_out.bte.eq(bus_in.bte),
            bus_out.cyc.eq(bus_in.cyc & ~hold),
            bus_out.stb.eq(bus_in.stb & ~hold),
            bus_in.ack.eq(bus_out.ack), bus_in.dat_r.eq(bus_out.dat_r), bus_in.err.eq(bus_out.err),
            last.eq((bus_in.cti != wishbone.CTI_BURST_INCREMENTING) | (count == max_burst - 1)),
        ]
        self.sync += [
            If(bus_out.ack & bus_in.cyc & bus_in.stb,
                If(last,
                    hold.eq(1), quiet.eq(0), count.eq(0)
                ).Else(
                    count.eq(count + 1)
                )
            ),
            If(hold,
                If(cs_n, If(quiet == gap, hold.eq(0)).Else(quiet.eq(quiet + 1))).Else(quiet.eq(0))
            ),
        ]


class HyperRAMInit(LiteXModule):
    """Reset pulse, power-on wait, then CR0 := 0x8FF7 (variable latency, 4 clocks, 32-byte wrap) and read-back
    of CR0, ID0 and ID1.  `done` rises when the device is ready for memory accesses."""
    def __init__(self, core, por_cycles=15000, rst_cycles=200, cr0=0x8FF7):
        self.done = Signal()
        self.cr0  = Signal(16)
        self.id0  = Signal(16)
        self.id1  = Signal(16)
        cnt  = Signal(16)
        step = Signal(2)
        reg  = core.reg

        self.fsm = fsm = FSM(reset_state="RESET")
        fsm.act("RESET",
            core.rst.eq(1),
            NextValue(cnt, cnt + 1),
            If(cnt == rst_cycles, NextValue(cnt, 0), NextState("POR")))
        fsm.act("POR",
            NextValue(cnt, cnt + 1),
            If(cnt == por_cycles, NextValue(cnt, 0), NextValue(step, 0), NextState("REG")))
        fsm.act("REG",
            reg.cyc.eq(1), reg.stb.eq(1),
            reg.we.eq(step == 0),
            reg.adr.eq(Array([2, 2, 0, 1])[step]),
            reg.dat_w.eq(cr0),
            If(reg.ack,
                Case(step, {
                    1: NextValue(self.cr0, reg.dat_r),
                    2: NextValue(self.id0, reg.dat_r),
                    3: NextValue(self.id1, reg.dat_r),
                }),
                NextValue(step, step + 1),
                If(step == 3, NextState("DONE"))))
        fsm.act("DONE", self.done.eq(1))


class BaseSoC(SoCCore):
    def __init__(self, sys_clk_freq=50e6, remote_ip="192.168.1.106", boot_file="kernel.bin",
                 load_addr=0x40200000, **kwargs):
        platform = Platform()
        kwargs.setdefault("ident", "LiteX Sonata open-flow")
        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)
        self.crg = _CRG(platform, sys_clk_freq)

        # HyperRAM main RAM ------------------------------------------------------------------------
        pads = platform.request("hyperram")
        self.hyperram = hr = HyperRAM(pads, latency=4, latency_mode="variable", clk_ratio="4:1",
                                      with_bursting=True, with_csr=False)
        self.hr_init = init = HyperRAMInit(hr.core)
        wb_cpu = wishbone.Interface(data_width=32, address_width=32, addressing="word")
        wb_gd  = wishbone.Interface(data_width=32, address_width=32, addressing="word")
        self.hr_guard = HyperRAMGuard(wb_cpu, wb_gd, pads.cs_n)
        # No access before CR0 is written: a read at the power-up latency would be misaligned.
        self.comb += [
            hr.bus.adr.eq(wb_gd.adr), hr.bus.dat_w.eq(wb_gd.dat_w), hr.bus.sel.eq(wb_gd.sel),
            hr.bus.we.eq(wb_gd.we), hr.bus.cti.eq(wb_gd.cti), hr.bus.bte.eq(wb_gd.bte),
            hr.bus.cyc.eq(wb_gd.cyc & init.done), hr.bus.stb.eq(wb_gd.stb & init.done),
            wb_gd.ack.eq(hr.bus.ack), wb_gd.dat_r.eq(hr.bus.dat_r),
        ]
        size = 8 * 1024 * 1024
        self.bus.add_slave("main_ram", wb_cpu, SoCRegion(origin=0x40000000, size=size, mode="rwx"))
        # OpenSBI at the top of the 8 MB, as in sonata-linux (the default would lie beyond the end).
        if "opensbi" in self.bus.regions:
            del self.bus.regions["opensbi"]
        self.bus.add_region("opensbi", SoCRegion(origin=0x40000000 + size - 0x80000, size=0x80000,
                                                 cached=True, linker=True))
        # ID and CR0 read-back, for the BIOS and for debugging.
        from litex.soc.interconnect.csr import CSRStatus
        self.hr_id0 = CSRStatus(16, name="hr_id0")
        self.hr_id1 = CSRStatus(16, name="hr_id1")
        self.hr_cr0 = CSRStatus(16, name="hr_cr0")
        self.hr_ok  = CSRStatus(1,  name="hr_ok")
        self.comb += [self.hr_id0.status.eq(init.id0), self.hr_id1.status.eq(init.id1),
                      self.hr_cr0.status.eq(init.cr0), self.hr_ok.status.eq(init.done)]

        # SPI flash, XIP ---------------------------------------------------------------------------
        from litespi.modules import W25Q256JVM
        from litespi.opcodes import SpiNorFlashOpCodes as Codes
        self.add_spi_flash(mode="4x", module=W25Q256JVM(Codes.READ_1_1_4), clk_freq=12.5e6,
                           with_master=True)

        # SPI Ethernet ------------------------------------------------------------------------------
        self.spi_eth = SPIHost(platform.request("spi_eth"))
        self.bus.add_slave("spi_eth", self.spi_eth.bus, SoCRegion(origin=0x80302000, size=0x2000, cached=False))
        self.irq.add("spi_eth")
        # The KSZ8851 can lose SPI sync and then only a hardware reset recovers it: eth_rst_n is a CSR
        # (1 = chip held in reset), pulsed by the BIOS before it talks to the chip.
        from litex.soc.interconnect.csr import CSRStorage
        self.eth_rst = CSRStorage(1, name="eth_rst", description="1 holds the KSZ8851 in reset (eth_rst_n low).")
        self.comb += platform.request("eth_rst_n").eq(~self.eth_rst.storage)
        # The 8 DIP switches select the TFTP server: 0 keeps the built-in address, any other value
        # is the last octet on the same subnet.
        from migen.genlib.cdc import MultiReg
        self.dip = CSRStatus(8, name="dip", description="DIP switches (raw pin levels).")
        self.specials += MultiReg(platform.request("user_sw"), self.dip.status)
        # LCD text console ---------------------------------------------------------------------------
        self.lcd = LCDText(platform.request("lcd"), sys_clk_freq)
        self.bus.add_slave("lcd", self.lcd.bus, SoCRegion(origin=0x80305000, size=0x200, cached=False))
        self.add_constant("LCD_BASE", 0x80305000)
        self.add_constant("SPIETH_BASE", 0x80302000)
        for i, b in enumerate(remote_ip.split(".")):
            self.add_constant("SPIETH_REMOTEIP%d" % (i + 1), int(b))
        self.add_constant("SPIETH_BOOT_FILENAME", boot_file)
        self.add_constant("SPIETH_LOAD_ADDR", load_addr)

        self.leds = LedChaser(pads=platform.request_all("user_led"), sys_clk_freq=sys_clk_freq)


def main():
    from litex.build.parser import LiteXArgumentParser
    parser = LiteXArgumentParser(platform=Platform, description="LiteX SoC on Sonata, open flow.")
    parser.add_target_argument("--sys-clk-freq", default=50e6, type=float)
    parser.add_target_argument("--remote-ip", default="192.168.1.106", help="TFTP server the BIOS boots from.")
    parser.add_target_argument("--boot-file", default="kernel.bin", help="File fetched from the TFTP server.")
    parser.add_target_argument("--load-addr", default=0x40200000, type=lambda v: int(v, 0),
                               help="Where the TFTP image is loaded and entered.")
    args = parser.parse_args()
    soc = BaseSoC(sys_clk_freq=args.sys_clk_freq, remote_ip=args.remote_ip, boot_file=args.boot_file,
                  load_addr=args.load_addr,
                  **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    # The BIOS is a local copy of LiteX's, with the SPI Ethernet driver and DHCP+TFTP boot added (bios/).
    builder.add_software_package("bios", src_dir=os.path.join(os.path.dirname(os.path.abspath(__file__)), "bios"))
    builder.build(**parser.toolchain_argdict)


if __name__ == "__main__":
    main()
