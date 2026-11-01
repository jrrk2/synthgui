// framing_miner.sv -- the frame buffer and register file that mine_ctrl drives,
// on the LiteEth (open) SGMII stack instead of Xilinx gig_ethernet_pcs_pma.
//
// Register map and buffer layout are those of cva6's framing_top_sgmii.sv at
// ~/cva6 cb702b40 ("Add CPU-less mining_top flow and mine_daemon"), which is
// what mine_ctrl.sv was written against:
//
//   0x0800 W/R  mac_address[31:0]
//   0x0808 W/R  {irq_en, promiscuous, spare[3:0], loopback, cooked, mac_address[47:32]}
//   0x0810 W    [10:0] TX length in bytes, [11] TX buffer select -- starts TX
//          R    {tx_busy[31], 4'b0, tx_frame_addr[26:16], 5'b0, tx_packet_length[10:0]}
//   0x0818 R    TX FCS (bit-reversed)
//   0x0820 R    0 (no MDIO: the SGMII PHY needs none here)
//   0x0828 W    lastbuf;  R  RX FCS (bit-reversed)
//   0x0830 W    firstbuf; R  {eth_irq[16], avail[15], lastbuf[14:10], nextbuf[9:5], firstbuf[4:0]}
//   0x0C00 R    RX length per buffer, 32 entries: [11] bad frame, [10:0] bytes
//   0x1000 W    TX buffer: 2 x 2 KB, half selected by address bit 11
//   0x10000 R   RX buffers: 2 KB each, buffer = address[15:11]
//
// What changed from cva6, and why:
//
//   * One clock.  With the LiteEth sgmii_soc the MAC, its RX stream and its TX
//     stream all run on mac_clk_in (the PCS's two recovered clocks end in its
//     retimer), so the bus side runs on that clock too and the cva6 CDC
//     synchronisers between msoc_clk and rx_clk/eth_clk have nothing to do.
//   * Memories.  RAMB16_S9_S36 (dualmem_widen / dualmem_widen8) is a Spartan-3
//     primitive the open flow has no cell for, and the TX read ran on ~eth_clk.
//     Both buffers are now one-write one-read memories on posedge clk that the
//     mapper infers as RAMB36E1: RX as 8 byte lanes of 4K x 8, TX as two
//     32-bit halves of 512 x 32.
//   * RX buffers: 16 x 2 KB (32 KB), not 32.  The pointers stay 5 bits wide and
//     the buffer index is taken mod 16; lastbuf is capped at 15 so no more than
//     15 frames are ever held, and 15 consecutive indices are distinct mod 16.
//     mine_ctrl writes lastbuf = 31 and is unchanged.
//   * TX.  cva6 ended a transmission when the PHY-side gmii_tx_en and tlast
//     coincided.  LiteEth's mac_gmii_tx_en is on the PCS TX clock, after a
//     store-and-forward retimer, so it is neither in this clock domain nor
//     high when the MAC takes tlast.  TX here is a small FSM on the AXI-stream
//     handshake alone: a write to 0x0810 streams that many bytes from the
//     selected half, tx_busy is high until the MAC has taken the last byte.
//   * No ILA, no MDIO, no eth_irq output (mine_ctrl polls).

`default_nettype none

module framing_miner (
  input  wire         clk,          // mac clock: bus, MAC and buffers
  input  wire         rst,          // synchronous to clk, active high

  // mine_ctrl bus
  input  wire [16:0]  core_lsu_addr,
  input  wire [63:0]  core_lsu_wdata,
  input  wire [7:0]   core_lsu_be,
  input  wire         ce_d,
  input  wire         we_d,
  input  wire         framing_sel,
  output logic [63:0] framing_rdata,

  // sgmii_soc (LiteEth) system side
  input  wire         clk_int,      // free-running fabric clock for the PCS
  input  wire         rst_int,      // active high

  input  wire         sgmii_rxp,
  input  wire         sgmii_rxn,
  output wire         sgmii_txp,
  output wire         sgmii_txn,
  input  wire         sgmii_refclk_p,
  input  wire         sgmii_refclk_n,
  output wire         phy_reset_n,

  output wire [15:0]  pcspma_status
);

  // ================================================================
  //  MAC + LiteEth PCS (ethmin's sgmii_soc_liteeth.sv)
  // ================================================================
  logic        tx_axis_tvalid, tx_axis_tlast;
  logic [7:0]  tx_axis_tdata;
  wire         tx_axis_tready;
  wire [7:0]   rx_axis_tdata;
  wire         rx_axis_tvalid, rx_axis_tlast, rx_axis_tuser;
  wire [31:0]  tx_fcs_reg, rx_fcs_reg;

  sgmii_soc #(.RETIME_MAC(1)) eth (
    .clk_int        (clk_int),
    .rst_int        (rst_int),
    .mac_clk_in     (clk),
    .eth_clk        (),             // == mac_clk_in; use clk (no second BUFG)
    .sgmii_rxp      (sgmii_rxp),
    .sgmii_rxn      (sgmii_rxn),
    .sgmii_txp      (sgmii_txp),
    .sgmii_txn      (sgmii_txn),
    .sgmii_refclk_p (sgmii_refclk_p),
    .sgmii_refclk_n (sgmii_refclk_n),
    .phy_reset_n    (phy_reset_n),
    .mac_gmii_tx_en (),
    .tx_axis_tvalid (tx_axis_tvalid),
    .tx_axis_tlast  (tx_axis_tlast),
    .tx_axis_tdata  (tx_axis_tdata),
    .tx_axis_tready (tx_axis_tready),
    .tx_axis_tuser  (1'b0),
    .rx_clk         (),             // == mac_clk_in
    .rx_axis_tdata  (rx_axis_tdata),
    .rx_axis_tvalid (rx_axis_tvalid),
    .rx_axis_tlast  (rx_axis_tlast),
    .rx_axis_tuser  (rx_axis_tuser),
    .rx_fcs_reg     (rx_fcs_reg),
    .tx_fcs_reg     (tx_fcs_reg),
    .pcspma_status  (pcspma_status),
    .dbg_enablealign(),
    .gtrefclk_bufg_out()
  );

  // ================================================================
  //  Registers
  // ================================================================
  logic [47:0] mac_address, rx_dest_mac;
  logic        irq_en, promiscuous, loopback, cooked;
  logic [3:0]  spare;
  logic [4:0]  firstbuf, nextbuf, lastbuf;
  logic [16:0] core_lsu_addr_dly;
  logic        ce_d_dly;

  wire reg_wr = framing_sel & we_d & (&core_lsu_be[3:0]) & (core_lsu_addr[16:11] == 6'b000001);
  wire [3:0] reg_idx = core_lsu_addr[6:3];

  // ================================================================
  //  RX: AXI stream -> 16 x 2 KB buffers
  // ================================================================
  logic [10:0] rx_addr_axis;
  logic        byte_sync;        // this frame has a buffer
  logic [11:0] rx_length_axis [0:31];
  logic        frame_done;       // one cycle after the last byte of an accepted frame
  logic        sync;

  wire buf_full = nextbuf == ((firstbuf + lastbuf) & 5'd31);

  always_ff @(posedge clk) begin
    frame_done <= 1'b0;
    if (rst) begin
      byte_sync    <= 1'b0;
      rx_addr_axis <= '0;
      rx_dest_mac  <= '0;
    end else if (rx_axis_tvalid) begin
      if (!byte_sync && !buf_full) byte_sync <= 1'b1;
      if (rx_addr_axis < 6) rx_dest_mac <= {rx_dest_mac[39:0], rx_axis_tdata};
      if (rx_axis_tlast) begin
        rx_length_axis[nextbuf] <= {rx_axis_tuser, rx_addr_axis + 11'd1};
        rx_addr_axis <= '0;
        byte_sync    <= 1'b0;
        // the first byte claims the buffer, so a frame that starts in a free
        // buffer is kept whole (byte_sync is set from the cycle after it)
        frame_done   <= byte_sync | !buf_full;
      end else begin
        rx_addr_axis <= rx_addr_axis + 11'd1;
      end
    end
  end

  // RX buffer memory: 8 byte lanes, word = {buffer[3:0], frame_byte[10:3]}
  wire [11:0] rx_wr_word = {nextbuf[3:0], rx_addr_axis[10:3]};
  wire [11:0] rx_rd_word = core_lsu_addr[14:3];
  logic [63:0] framing_rdata_pkt;

  genvar lane;
  generate
    for (lane = 0; lane < 8; lane++) begin : gen_rx_lane
      logic [7:0] mem [0:4095];
      always_ff @(posedge clk) begin
        if (rx_axis_tvalid && rx_addr_axis[2:0] == 3'(lane))
          mem[rx_wr_word] <= rx_axis_tdata;
        framing_rdata_pkt[lane*8 +: 8] <= mem[rx_rd_word];
      end
    end
  endgenerate

  // ================================================================
  //  TX: 2 x 2 KB buffer -> AXI stream
  // ================================================================
  logic        tx_busy, tx_buf_sel;
  logic [10:0] tx_packet_length, tx_frame_addr;

  wire tx_go   = reg_wr && reg_idx == 4'd2 && !tx_busy && core_lsu_wdata[10:0] != 0;
  wire tx_stop = reg_wr && reg_idx == 4'd3;
  wire tx_take = tx_axis_tvalid && tx_axis_tready;
  wire tx_end  = tx_take && tx_axis_tlast;

  // next byte address and buffer, so the registered read below holds the word
  // for tx_frame_addr in the same cycle tx_frame_addr holds it
  wire [10:0] tx_addr_nx = tx_go ? 11'd0 : (tx_take && !tx_axis_tlast) ? tx_frame_addr + 11'd1 : tx_frame_addr;
  wire        tx_sel_nx  = tx_go ? core_lsu_wdata[11] : tx_buf_sel;

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_busy          <= 1'b0;
      tx_buf_sel       <= 1'b0;
      tx_packet_length <= '0;
      tx_frame_addr    <= '0;
      tx_axis_tvalid   <= 1'b0;
    end else begin
      tx_frame_addr <= tx_addr_nx;
      tx_buf_sel    <= tx_sel_nx;
      if (tx_go) begin
        tx_busy          <= 1'b1;
        tx_packet_length <= core_lsu_wdata[10:0];
      end
      // valid from the cycle after go: the read of word 0 has landed by then
      tx_axis_tvalid <= tx_busy && !tx_end && !tx_stop;
      if (tx_end || tx_stop) tx_busy <= 1'b0;
    end
  end

  assign tx_axis_tlast = tx_frame_addr == tx_packet_length - 11'd1;

  // TX buffer memory: 2 x 32-bit halves, word = {sel, frame_byte[10:3]} (512 words)
  wire [8:0] tx_wr_word = core_lsu_addr[11:3];
  wire       tx_wr      = framing_sel & ce_d & we_d & (core_lsu_addr[16:12] == 5'b00001);
  wire [8:0] tx_rd_word = {tx_sel_nx, tx_addr_nx[10:3]};
  logic [63:0] tx_q;

  generate
    for (lane = 0; lane < 2; lane++) begin : gen_tx_half
      logic [31:0] mem [0:511];
      always_ff @(posedge clk) begin
        if (tx_wr && (|core_lsu_be[lane*4 +: 4]))
          mem[tx_wr_word] <= core_lsu_wdata[lane*32 +: 32];
        tx_q[lane*32 +: 32] <= mem[tx_rd_word];
      end
    end
  endgenerate

  assign tx_axis_tdata = tx_q[{tx_frame_addr[2:0], 3'b000} +: 8];

  // ================================================================
  //  Register writes, buffer pointers, destination filter
  // ================================================================
  logic avail;

  always_ff @(posedge clk) begin
    if (rst) begin
      core_lsu_addr_dly <= '0;
      ce_d_dly    <= 1'b0;
      mac_address <= 48'h230100890702;
      cooked      <= 1'b0;
      loopback    <= 1'b0;
      spare       <= 4'b0;
      promiscuous <= 1'b0;
      irq_en      <= 1'b0;
      sync        <= 1'b0;
      firstbuf    <= '0;
      lastbuf     <= '0;
      nextbuf     <= '0;
      avail       <= 1'b0;
    end else begin
      core_lsu_addr_dly <= core_lsu_addr;
      ce_d_dly <= ce_d;
      avail    <= nextbuf != firstbuf;
      if (reg_wr)
        case (reg_idx)
          4'd0: mac_address[31:0] <= core_lsu_wdata[31:0];
          4'd1: {irq_en, promiscuous, spare, loopback, cooked, mac_address[47:32]} <= core_lsu_wdata[23:0];
          4'd5: lastbuf  <= (core_lsu_wdata[4:0] > 5'd15) ? 5'd15 : core_lsu_wdata[4:0];
          4'd6: firstbuf <= core_lsu_wdata[4:0];
          default: ;
        endcase
      // A finished frame is kept (nextbuf advances) if it is addressed to us,
      // broadcast, IPv4 multicast, or we are promiscuous -- cva6's filter.
      sync <= 1'b0;
      if (frame_done)
        sync <= (rx_dest_mac[47:24] == 24'h01005E) | (&rx_dest_mac)
              | (mac_address == rx_dest_mac) | promiscuous;
      if (sync) nextbuf <= nextbuf + 5'd1;
    end
  end

  // ================================================================
  //  Read mux (address and enable from the previous cycle, as cva6)
  // ================================================================
  wire [31:0] tx_fcs_rev, rx_fcs_rev;
  generate
    for (lane = 0; lane < 32; lane++) begin : gen_rev
      assign tx_fcs_rev[lane] = tx_fcs_reg[31-lane];
      assign rx_fcs_rev[lane] = rx_fcs_reg[31-lane];
    end
  endgenerate

  wire eth_irq = avail & irq_en;

  always_comb
    casez ({ce_d_dly, core_lsu_addr_dly[16:3]})
      15'b100_0001_0???_0000: framing_rdata = {32'd0, mac_address[31:0]};
      15'b100_0001_0???_0001: framing_rdata = {40'd0, irq_en, promiscuous, spare, loopback, cooked, mac_address[47:32]};
      15'b100_00??_????_0010: framing_rdata = {32'd0, tx_busy, 4'b0, tx_frame_addr, 5'b0, tx_packet_length};
      15'b100_0001_0???_0011: framing_rdata = {32'd0, tx_fcs_rev};
      15'b100_0001_0???_0100: framing_rdata = '0;
      15'b100_0001_0???_0101: framing_rdata = {32'd0, rx_fcs_rev};
      15'b100_0001_0???_0110: framing_rdata = {47'd0, eth_irq, avail, lastbuf, nextbuf, firstbuf};
      15'b100_0001_1??_?????: framing_rdata = {52'd0, rx_length_axis[core_lsu_addr_dly[7:3]]};
      15'b1_1?_????????????:  framing_rdata = framing_rdata_pkt;
      default:                framing_rdata = '0;
    endcase

endmodule

`default_nettype wire
