// vc707_miner.sv -- kHeavyHash (Kaspa) miner for the VC707, open flow.
//
// ~/cva6 mining_top.sv (cb702b40) without Xilinx IP: the SGMII PCS/PMA is
// LiteEth's (ethmin's sgmii_soc_liteeth.sv on the GTXE2), the framing BRAMs
// are inferred (framing_miner.sv), and there is no ILA.  mine_ctrl.sv and the
// HeavyHash RTL are unchanged.  mine_daemon on the workstation talks to it
// with raw EtherType 0x4B41 frames and to kaspad over wRPC.
//
//   clk_sys = 1 GHz / SYS_DIV   LiteEth PCS fabric clock (clk_int)
//   clk_mac = 1 GHz / MAC_DIV   MAC, framing buffers, mine_ctrl and the lanes:
//                               one domain, as mining_top had on userclk2
//
// LEDs: 0 mining, 1 found (until the next job), 2 link up, 3 lanes busy,
//       4 PCS user clocks locked, 5 an RX frame was ever seen,
//       6 clk_mac heartbeat, 7 clk_sys heartbeat (fast while in reset)

`default_nettype none

`ifndef MAC_DIV
`define MAC_DIV 10
`endif
`ifndef SYS_DIV
`define SYS_DIV 20.000
`endif
`ifndef LANES
`define LANES 1
`endif

module vc707_miner (
  input  wire       IO_CLK_P,        // 200 MHz LVDS system clock
  input  wire       IO_CLK_N,
  input  wire       IO_RST,          // CPU_RESET, active high
  output wire [7:0] LED,

  input  wire       sgmii_rxp,
  input  wire       sgmii_rxn,
  output wire       sgmii_txp,
  output wire       sgmii_txn,
  input  wire       sgmii_refclk_p,
  input  wire       sgmii_refclk_n,
  output wire       eth_rst_n
);
  // ---------------------------------------------------------------
  //  Clocks and resets
  // ---------------------------------------------------------------
  wire clk_sys, clk_mac, rst_sys_n, locked;
  clkgen_vc707 #(.MAC_DIV(`MAC_DIV), .SYS_DIV(`SYS_DIV)) clkgen (
    .IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(~IO_RST),
    .clk_sys(clk_sys), .clk_mac(clk_mac),
    .rst_sys_n(rst_sys_n), .locked(locked));

  // CPU_RESET synchronised to clk_sys and held 2^16 cycles after release
  // (ethmin's scheme); resetn releases the PCS, then the MAC domain.
  reg [1:0]  button_sync = 2'b00;
  reg [15:0] button_hold = 16'd0;
  always @(posedge clk_sys) begin
    button_sync <= {button_sync[0], IO_RST};
    if (button_sync[1]) button_hold <= 16'd0;
    else if (!(&button_hold)) button_hold <= button_hold + 16'd1;
  end
  wire resetn = rst_sys_n && (&button_hold);

  reg [2:0] mac_rst_sync = 3'b000;
  always @(posedge clk_mac or negedge resetn)
    if (!resetn) mac_rst_sync <= 3'b000;
    else         mac_rst_sync <= {mac_rst_sync[1:0], 1'b1};
  wire rst_mac_n = mac_rst_sync[2];

  // ---------------------------------------------------------------
  //  The miner
  // ---------------------------------------------------------------
  wire [15:0] pcspma_status;
  wire        led_mining, led_found, hh_busy;

  miner_core #(.LANES(`LANES)) u_core (
    .clk_mac        (clk_mac),
    .rst_mac_n      (rst_mac_n),
    .clk_sys        (clk_sys),
    .resetn         (resetn),
    .sgmii_rxp      (sgmii_rxp),
    .sgmii_rxn      (sgmii_rxn),
    .sgmii_txp      (sgmii_txp),
    .sgmii_txn      (sgmii_txn),
    .sgmii_refclk_p (sgmii_refclk_p),
    .sgmii_refclk_n (sgmii_refclk_n),
    .eth_rst_n      (eth_rst_n),
    .pcspma_status  (pcspma_status),
    .led_mining     (led_mining),
    .led_found      (led_found),
    .hh_busy        (hh_busy)
  );

  // ---------------------------------------------------------------
  //  LEDs
  // ---------------------------------------------------------------
  reg [25:0] hb_sys = 26'd0;
  always @(posedge clk_sys) hb_sys <= hb_sys + 26'd1;
  reg [25:0] hb_mac = 26'd0;
  always @(posedge clk_mac) hb_mac <= hb_mac + 26'd1;

  assign LED = {resetn ? hb_sys[25] : hb_sys[22],
                hb_mac[25],
                pcspma_status[6],     // PCS ever drove rx_dv
                pcspma_status[1],     // phy_ready
                hh_busy,
                pcspma_status[0],     // link up
                led_found,
                led_mining};

endmodule

`default_nettype wire
