`default_nettype none
// BPI flash over JTAG for the VC707's linear BPI flash (U3, Micron PC28F00AG18FE, 128 MB, 16 bits wide).
//
// The bridge openFPGALoader talks to (deps/openFPGALoader/bpiOverJtag, Apache-2.0): its core with the data bus split into
// in/out/tristate (bpiOverJtag_core_io.v, a marked copy: the mapper does not make pad buffers from a tri-state assign), and a
// top level that is theirs (xilinx_bpiOverJtag.v) with the address bus cut to what one boot slot needs. The flash holds four
// bitstreams 32 MiB apart; which one the FPGA boots from, and which one this bridge reads and writes, is chosen by SW11
// positions 1 and 2, which drive the flash's two top address lines (FLASH_A25, FLASH_A24: the RS1 and RS0 nets). The bridge
// drives the 24 lines below them and leaves those two to the switches, so it never fights the switch for a net.
//
// Load it with `openFPGALoader --cable digilent ...` through the JTAG USER1 and USER4 registers (BSCANE2).
module vc707_bpi_bridge (
	output wire [23:0] bpi_addr,   // bit n is flash pin A<n+1>, net FLASH_A<n>: the word address inside the slot
	inout  wire [15:0] bpi_dq,
	output wire        bpi_ce_n,
	output wire        bpi_oe_n,
	output wire        bpi_we_n,
	output wire        bpi_adv_n
);
	wire capture, drck_raw, drck, sel, update, shift, tdi, tdo;
	wire ver_sel, ver_cap, ver_shift, ver_drck_raw, ver_drck, ver_tdi, ver_tdo;
	wire [25:1] addr;                 // the core's 25 word-address lines; the top one stays inside the FPGA
	assign bpi_addr = addr[24:1];     // the core numbers its lines 1..25, like the flash pins

	wire [15:0] dq_i, dq_o;
	wire        dq_t;
	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : dq_pad
			IOBUF iobuf (.IO(bpi_dq[i]), .I(dq_o[i]), .T(dq_t), .O(dq_i[i]));
		end
	endgenerate

	bpiOverJtag_core core (
		.sel(sel), .capture(capture), .update(update), .shift(shift), .drck(drck), .tdi(tdi), .tdo(tdo),
		.ver_sel(ver_sel), .ver_cap(ver_cap), .ver_shift(ver_shift), .ver_drck(ver_drck), .ver_tdi(ver_tdi), .ver_tdo(ver_tdo),
		.bpi_addr(addr), .bpi_dq_i(dq_i), .bpi_dq_o(dq_o), .bpi_dq_t(dq_t),
		.bpi_ce_n(bpi_ce_n), .bpi_oe_n(bpi_oe_n), .bpi_we_n(bpi_we_n), .bpi_adv_n(bpi_adv_n)
	);

	// The flash's CLK pin is the FPGA's CCLK (UG885 Table 1-5), which floats once the FPGA is configured over JTAG. The bridge
	// reads and writes asynchronously, so hold the clock low through the user-clock path of STARTUPE2.
	STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) cclk_low (
		.CFGCLK(), .CFGMCLK(), .EOS(), .PREQ(), .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
		.USRCCLKO(1'b0), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1));

	// The JTAG clocks go on global clock buffers: routed through the fabric their skew breaks hold time inside the core.
	BUFG drck_bufg (.I(drck_raw), .O(drck));
	BUFG ver_drck_bufg (.I(ver_drck_raw), .O(ver_drck));

	// main data register (USER1)
	BSCANE2 #(.JTAG_CHAIN(1)) bscan_main (
		.CAPTURE(capture), .DRCK(drck_raw), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift), .TCK(), .TDI(tdi), .TMS(),
		.UPDATE(update), .TDO(tdo));
	// version register (USER4)
	BSCANE2 #(.JTAG_CHAIN(4)) bscan_version (
		.CAPTURE(ver_cap), .DRCK(ver_drck_raw), .RESET(), .RUNTEST(), .SEL(ver_sel), .SHIFT(ver_shift), .TCK(), .TDI(ver_tdi),
		.TMS(), .UPDATE(), .TDO(ver_tdo));
endmodule
