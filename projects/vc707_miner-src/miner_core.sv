// miner_core.sv -- the board-independent miner: LiteEth SGMII + MAC + frame
// buffers (framing_miner), mine_ctrl, and the HeavyHash lanes, all on one
// clock (each lane through its own BUFHCE).  vc707_miner.sv wraps it with the VC707's clocks, reset and LEDs;
// sim/tb_miner.sv drives it with mine_daemon's frames.

`default_nettype none

module miner_core #(
  parameter int unsigned LANES = 1
) (
  input  wire       clk_mac,         // MAC, buffers, mine_ctrl, lanes
  input  wire       rst_mac_n,       // synchronous to clk_mac
  input  wire       clk_sys,         // LiteEth PCS fabric clock
  input  wire       resetn,          // clk_sys domain

  input  wire       sgmii_rxp,
  input  wire       sgmii_rxn,
  output wire       sgmii_txp,
  output wire       sgmii_txn,
  input  wire       sgmii_refclk_p,
  input  wire       sgmii_refclk_n,
  output wire       eth_rst_n,

  output wire [15:0] pcspma_status,
  output wire       led_mining,
  output wire       led_found,
  output wire       hh_busy
);
  import keccak_pkg::*;

  // ---------------------------------------------------------------
  //  Ethernet: LiteEth SGMII + MAC + frame buffers
  // ---------------------------------------------------------------
  wire [16:0] lsu_addr;
  wire [63:0] lsu_wdata, lsu_rdata;
  wire [7:0]  lsu_be;
  wire        lsu_ce, lsu_we, lsu_sel;

  framing_miner u_framing (
    .clk            (clk_mac),
    .rst            (!rst_mac_n),
    .core_lsu_addr  (lsu_addr),
    .core_lsu_wdata (lsu_wdata),
    .core_lsu_be    (lsu_be),
    .ce_d           (lsu_ce),
    .we_d           (lsu_we),
    .framing_sel    (lsu_sel),
    .framing_rdata  (lsu_rdata),
    .clk_int        (clk_sys),
    .rst_int        (!resetn),
    .sgmii_rxp      (sgmii_rxp),
    .sgmii_rxn      (sgmii_rxn),
    .sgmii_txp      (sgmii_txp),
    .sgmii_txn      (sgmii_txn),
    .sgmii_refclk_p (sgmii_refclk_p),
    .sgmii_refclk_n (sgmii_refclk_n),
    .phy_reset_n    (eth_rst_n),
    .pcspma_status  (pcspma_status)
  );

  // ---------------------------------------------------------------
  //  Mining controller and lanes (all on clk_mac)
  // ---------------------------------------------------------------
  wire          hh_start, hh_stop, hh_found;
  wire [63:0]   hh_nonce_found, hh_hash_count, hh_nonce_start;
  wire [1599:0] hh_mid_state_1, hh_mid_state_2;
  wire [RATE-1:0] hh_msg_block;
  wire [255:0]  hh_target, hh_mat_wr_data;
  wire          hh_mat_wr_en;
  wire [5:0]    hh_mat_wr_addr;

  mine_ctrl i_mine_ctrl (
    .clk            (clk_mac),
    .rst_n          (rst_mac_n),
    .core_lsu_addr  (lsu_addr),
    .core_lsu_wdata (lsu_wdata),
    .core_lsu_be    (lsu_be),
    .ce_d           (lsu_ce),
    .we_d           (lsu_we),
    .framing_sel    (lsu_sel),
    .framing_rdata  (lsu_rdata),
    .hh_start       (hh_start),
    .hh_stop        (hh_stop),
    .hh_busy        (hh_busy),
    .hh_found       (hh_found),
    .hh_nonce_found (hh_nonce_found),
    .hh_hash_count  (hh_hash_count),
    .hh_mid_state_1 (hh_mid_state_1),
    .hh_mid_state_2 (hh_mid_state_2),
    .hh_msg_block   (hh_msg_block),
    .hh_target      (hh_target),
    .hh_nonce_start (hh_nonce_start),
    .hh_mat_wr_en   (hh_mat_wr_en),
    .hh_mat_wr_addr (hh_mat_wr_addr),
    .hh_mat_wr_data (hh_mat_wr_data),
    .led_mining     (led_mining),
    .led_found      (led_found),
    .dbg_state      (),
    .dbg_init_step  (),
    .dbg_frame_type (),
    .dbg_wcnt       (),
    .dbg_cur_buf    (),
    .dbg_flags      ()
  );

  // heavyhash_lanes: one BUFHCE (one clock region) per lane, configured
  // over a narrow chain; see its header
  heavyhash_lanes #(.NUM_LANES(LANES)) i_hh (
    .clk         (clk_mac),
    .rst_n       (rst_mac_n),
    .start       (hh_start),
    .stop        (hh_stop),
    .busy        (hh_busy),
    .found       (hh_found),
    .mid_state_1 (hh_mid_state_1),
    .mid_state_2 (hh_mid_state_2),
    .msg_block   (hh_msg_block),
    .target      (hh_target),
    .nonce_start (hh_nonce_start),
    .nonce_found (hh_nonce_found),
    .hash_count  (hh_hash_count),
    .mat_wr_en   (hh_mat_wr_en),
    .mat_wr_addr (hh_mat_wr_addr),
    .mat_wr_data (hh_mat_wr_data)
  );

endmodule

`default_nettype wire
