// sgmii_soc_stub.sv -- simulation stand-in for sgmii_soc_liteeth.sv: the same
// module name and ports, with the MAC's AXI streams wired to tb_miner instead
// of a PCS.  RX bytes come from tb_miner.rx_*; TX is always ready and
// tb_miner watches tx_axis_* through this instance.

`default_nettype none

module sgmii_soc #(
    parameter integer RETIME_MAC = 1
) (
    input wire          clk_int,
    input wire          rst_int,
    input wire          mac_clk_in,
    output wire         eth_clk,
    input wire          sgmii_rxp,
    input wire          sgmii_rxn,
    output wire         sgmii_txp,
    output wire         sgmii_txn,
    input wire          sgmii_refclk_p,
    input wire          sgmii_refclk_n,
    output wire         phy_reset_n,
    output wire         mac_gmii_tx_en,
    input wire          tx_axis_tvalid,
    input wire          tx_axis_tlast,
    input wire [7:0]    tx_axis_tdata,
    output wire         tx_axis_tready,
    input wire          tx_axis_tuser,
    output wire         rx_clk,
    output wire [7:0]   rx_axis_tdata,
    output wire         rx_axis_tvalid,
    output wire         rx_axis_tlast,
    output wire         rx_axis_tuser,
    output wire [31:0]  rx_fcs_reg,
    output wire [31:0]  tx_fcs_reg,
    output wire [15:0]  pcspma_status,
    output wire         dbg_enablealign,
    output wire         gtrefclk_bufg_out
);
    assign eth_clk        = mac_clk_in;
    assign rx_clk         = mac_clk_in;
    assign sgmii_txp      = 1'b0;
    assign sgmii_txn      = 1'b1;
    assign phy_reset_n    = ~rst_int;
    assign mac_gmii_tx_en = 1'b0;
    assign tx_axis_tready = tb_miner.tx_ready;
    assign rx_axis_tdata  = tb_miner.rx_tdata;
    assign rx_axis_tvalid = tb_miner.rx_tvalid;
    assign rx_axis_tlast  = tb_miner.rx_tlast;
    assign rx_axis_tuser  = 1'b0;
    assign rx_fcs_reg     = 32'h0;
    assign tx_fcs_reg     = 32'h0;
    assign pcspma_status  = 16'h0003;   // link up, PCS ready
    assign dbg_enablealign   = 1'b0;
    assign gtrefclk_bufg_out = 1'b0;
    always @(posedge mac_clk_in)
        if (tx_axis_tvalid && tx_axis_tready) tb_miner.tx_byte(tx_axis_tdata, tx_axis_tlast);
endmodule

`default_nettype wire
