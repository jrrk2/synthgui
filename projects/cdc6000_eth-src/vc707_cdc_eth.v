// vc707_cdc_eth -- the CDC 6000 core with the VC707's SGMII Ethernet: the clocking, PCS/PMA and MAC of
// fpga/vc707-ethmin/vc707_ethmin_vm.v, with cdc_eth_core in place of the OCaml VM.  The core runs the Pascal compiler
// (mem.hex: runtime, compiler, NFS driver) and reaches its source and results through NFS over UDP, from the server
// and export set in nfs/nfsdrv.pas (192.168.1.106, /srv/nfs/cdc, the board being 192.168.1.77).
//
// LEDs: 7 halted, 6 fault, 5:0 the program's; the UART (115200 8N1) carries the shell and the driver's diagnostics.
`default_nettype none
module vc707_cdc_eth (
	input  wire       IO_CLK_P,
	input  wire       IO_CLK_N,
	input  wire       IO_RST,
	output wire [7:0] LED,
	input  wire [7:0] GPIO_DIP_SW,
	input  wire [4:0] GPIO_SW,
	input  wire       UART_RX,
	output wire       UART_TX,
	input  wire       sgmii_rxp,
	input  wire       sgmii_rxn,
	output wire       sgmii_txp,
	output wire       sgmii_txn,
	input  wire       sgmii_refclk_p,
	input  wire       sgmii_refclk_n,
	output wire       eth_rst_n
);
`ifndef MAC_DIV
`define MAC_DIV 8
`endif
`ifndef SYS_DIV
`define SYS_DIV 20.000
`endif
`ifndef CLK_HZ
`define CLK_HZ 50_000_000
`endif
`ifndef CORE_SB
`define CORE_SB 0          // 1: the scoreboarded core
`endif
	wire clk_sys, clk_mac, rst_sys_n, locked;
	clkgen_vc707 #(.MAC_DIV(`MAC_DIV), .SYS_DIV(`SYS_DIV)) clkgen (
		.IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(~IO_RST),
		.clk_sys(clk_sys), .clk_mac(clk_mac), .rst_sys_n(rst_sys_n), .locked(locked));
	reg [1:0]  button_sync = 2'b00;
	reg [15:0] button_hold = 16'd0;
	always @(posedge clk_sys) begin
		button_sync <= {button_sync[0], IO_RST};
		if (button_sync[1]) button_hold <= 16'd0;
		else if (!(&button_hold)) button_hold <= button_hold + 16'd1;
	end
	wire resetn = rst_sys_n && (&button_hold);
	wire eth_clk, rx_clk;
	wire eth_rst = ~resetn;

	wire [7:0] rx_tdata, tx_tdata;
	wire       rx_tvalid, rx_tlast, rx_tuser;
	wire       tx_tvalid, tx_tlast, tx_tready, tx_tuser;
	wire [15:0] pcspma_status;
	sgmii_soc #(.RETIME_MAC(1)) eth (
		.clk_int(clk_sys), .rst_int(~resetn), .mac_clk_in(clk_mac), .eth_clk(eth_clk),
		.sgmii_rxp(sgmii_rxp), .sgmii_rxn(sgmii_rxn), .sgmii_txp(sgmii_txp), .sgmii_txn(sgmii_txn),
		.sgmii_refclk_p(sgmii_refclk_p), .sgmii_refclk_n(sgmii_refclk_n), .phy_reset_n(eth_rst_n),
		.mac_gmii_tx_en(),
		.tx_axis_tvalid(tx_tvalid), .tx_axis_tlast(tx_tlast), .tx_axis_tdata(tx_tdata), .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser), .rx_clk(rx_clk),
		.rx_axis_tdata(rx_tdata), .rx_axis_tvalid(rx_tvalid), .rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
		.rx_fcs_reg(), .tx_fcs_reg(), .pcspma_status(pcspma_status));

	wire [7:0] core_led;
	wire halted, fault;
	cdc_eth_core #(.CLK_HZ(`CLK_HZ), .CORE_SB(`CORE_SB)) core (
		.clk_sys(clk_sys), .resetn(resetn), .DIP(GPIO_DIP_SW), .BTN(GPIO_SW),
		.eth_clk(clk_mac), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_tdata), .rx_axis_tvalid(rx_tvalid), .rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
		.tx_axis_tdata(tx_tdata), .tx_axis_tvalid(tx_tvalid), .tx_axis_tlast(tx_tlast), .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser), .pcspma_status(pcspma_status),
		.LED(core_led), .UART_RX(UART_RX), .UART_TX(UART_TX), .halted(halted), .fault(fault));

	reg [25:0] hb_cnt = 26'd0;
	always @(posedge clk_sys) hb_cnt <= hb_cnt + 26'd1;
	assign LED = {core_led[7:1], hb_cnt[25] ^ core_led[0]};
endmodule
`default_nettype wire
