// mine_ctrl.sv — Ethernet frame-based mining controller
//
// Single clock domain (125 MHz userclk2 from SGMII PCS/PMA).
// Replaces CVA6 CPU + AXI-Lite register file for HeavyHash mining.
//
// Reads CONFIG frames from framing_top RX BRAM, drives heavyhash_multi
// directly (same clock, no CDC). Sends NONCE_FOUND / HEARTBEAT / ACK / NAK
// frames via TX BRAM.
//
// Frame types (EtherType 0x4B41):
//   0x01 CONFIG_HDR  (WS->FPGA): mid_states + msg_block + target + nonce_start
//   0x02 CONFIG_MAT  (WS->FPGA): 32 matrix rows per frame
//   0x03 NONCE_FOUND (FPGA->WS): 8-byte found nonce
//   0x04 HEARTBEAT   (FPGA->WS): hash_count + status + uptime
//   0x05 NAK         (FPGA->WS): bad FCS on received frame
//   0x06 ACK         (FPGA->WS): config acknowledged
//
// CONFIG_HDR layout (592 bytes):
//   [0:13]  Ethernet header (dst+src MAC, ethertype 0x4B41)
//   [14]    type=0x01, [15] seq
//   [16:215]  mid_state_1 (200 bytes LE)
//   [216:415] mid_state_2 (200 bytes LE)
//   [416:551] msg_block   (136 bytes LE)
//   [552:583] target      (32 bytes LE)
//   [584:591] nonce_start (8 bytes LE)
//
// CONFIG_MAT layout (1048 bytes):
//   [0:13]  Ethernet header
//   [14]    type=0x02, [15] seq
//   [16]    row_offset (0 or 32), [17:23] reserved
//   [24:1047] 32 rows x 32 bytes (256 bits LE each)
//
// BRAM byte order: little-endian within 64-bit words.
//   Frame byte N -> word N/8, bits [(N%8+1)*8-1 : (N%8)*8]
//
// Bus timing: registered outputs -> 2-cycle read latency.
//   Cycle 0: assert addr+ce_d  (mine_ctrl posedge)
//   Cycle 1: framing_top captures, BRAM reads  (framing_top posedge)
//   Cycle 2: framing_rdata valid, mine_ctrl captures (mine_ctrl posedge)

`default_nettype none

module mine_ctrl
  import keccak_pkg::*,
         heavyhash_pkg::*;
(
  input  wire           clk,        // 125 MHz (userclk2)
  input  wire           rst_n,

  // --- framing_top bus (directly replaces CPU LSU) ---
  output logic [16:0]   core_lsu_addr,
  output logic [63:0]   core_lsu_wdata,
  output logic [7:0]    core_lsu_be,
  output logic          ce_d,
  output logic          we_d,
  output logic          framing_sel,
  input  wire  [63:0]   framing_rdata,

  // --- heavyhash_multi (same clock, direct wires) ---
  output logic          hh_start,
  output logic          hh_stop,
  input  wire           hh_busy,
  input  wire           hh_found,
  input  wire  [63:0]   hh_nonce_found,
  input  wire  [63:0]   hh_hash_count,
  output logic [1599:0] hh_mid_state_1,
  output logic [1599:0] hh_mid_state_2,
  output logic [RATE-1:0] hh_msg_block,
  output logic [255:0]  hh_target,
  output logic [63:0]   hh_nonce_start,
  output logic          hh_mat_wr_en,
  output logic [5:0]    hh_mat_wr_addr,
  output logic [255:0]  hh_mat_wr_data,

  // --- Status ---
  output logic          led_mining,
  output logic          led_found,

  // --- Debug (directly connected to ILA in mining_top) ---
  output logic [3:0]   dbg_state,
  output logic [1:0]   dbg_init_step,
  output logic [7:0]   dbg_frame_type,
  output logic [7:0]   dbg_wcnt,
  output logic [4:0]   dbg_cur_buf,
  output logic [3:0]   dbg_flags        // {got_hdr, got_mat0, got_mat1, mining_active}
);

  // ================================================================
  //  Constants
  // ================================================================
  localparam [15:0] ETHERTYPE     = 16'h4B41;
  localparam [7:0]  FT_CONFIG_HDR = 8'h01;
  localparam [7:0]  FT_CONFIG_MAT = 8'h02;
  localparam [7:0]  FT_NONCE      = 8'h03;
  localparam [7:0]  FT_HEARTBEAT  = 8'h04;
  localparam [7:0]  FT_NAK        = 8'h05;
  localparam [7:0]  FT_ACK        = 8'h06;

  // FPGA MAC (locally administered)
  localparam [47:0] FPGA_MAC = 48'h02_00_00_4B_41_31;

  // CONFIG_HDR word boundaries (64-bit words from frame start)
  localparam W_HDR_END    = 8'd1;    // words 0-1: eth header
  localparam W_MS1_START  = 8'd2;    // words 2-26: mid_state_1 (25 words)
  localparam W_MS1_END    = 8'd26;
  localparam W_MS2_START  = 8'd27;   // words 27-51: mid_state_2 (25 words)
  localparam W_MS2_END    = 8'd51;
  localparam W_MSG_START  = 8'd52;   // words 52-68: msg_block (17 words)
  localparam W_MSG_END    = 8'd68;
  localparam W_TGT_START  = 8'd69;   // words 69-72: target (4 words)
  localparam W_TGT_END    = 8'd72;
  localparam W_NONCE_W    = 8'd73;   // word 73: nonce_start
  localparam W_CFG_LAST   = 8'd73;

  // CONFIG_MAT word boundaries
  localparam W_ROWOFF     = 8'd2;    // word 2: row_offset in byte 0
  localparam W_MDAT_START = 8'd3;    // words 3-130: 32 rows x 4 words
  localparam W_MDAT_END   = 8'd130;

  // Heartbeat interval: ~100ms at 125 MHz
  localparam [23:0] HB_INTERVAL = 24'd12_500_000;

  // ================================================================
  //  State machine
  // ================================================================
  typedef enum logic [3:0] {
    S_INIT,         // write MAC, lastbuf, promiscuous on startup
    S_IDLE,
    S_POLL_WAIT,    // bus read latency (status register)
    S_POLL_DONE,    // check avail
    S_LEN_WAIT,     // bus read latency (frame length)
    S_LEN_DONE,     // check FCS, start frame read
    S_FRAME_WAIT,   // bus read latency (frame word)
    S_FRAME_PROC,   // process captured word
    S_MAT_WR,       // assert mat_wr_en for 1 cycle
    S_TX_WR,        // write 1 TX BRAM word
    S_TX_WAIT,      // read TX status, wait for tx_busy clear
    S_TX_WAIT_DONE, // check tx_busy before triggering
    S_TX_GO,        // write tx_packet_length, trigger TX
    S_ADV_BUF,      // write firstbuf + 1
    S_DONE          // post-advance: start mining or idle
  } state_t;

  state_t state;

  // ================================================================
  //  Registers
  // ================================================================
  logic [7:0]   wcnt;              // word counter for sequential read/write
  logic [4:0]   cur_buf;           // RX buffer index being processed
  logic [7:0]   frame_type;        // current frame type
  logic [7:0]   frame_seq;         // current frame seq
  logic [10:0]  frame_len;         // frame length (bytes)
  logic         frame_fcs_err;     // FCS error on current frame

  // Config tracking
  logic         got_hdr, got_mat0, got_mat1;
  logic         mining_active;

  // Matrix row accumulator
  logic [1:0]   mat_sub;           // 0-3: which 64-bit chunk of 256-bit row
  logic [5:0]   mat_abs_row;       // absolute row number (row_offset + local)
  logic [5:0]   mat_row_offset;    // base from CONFIG_MAT frame
  logic [255:0] mat_row_acc;       // accumulating 256-bit row

  // Workstation MAC (learned from source of received frames)
  logic [47:0]  ws_mac;

  // TX building
  logic [7:0]   tx_type;           // frame type being sent
  logic [7:0]   tx_seq;            // seq for ACK/NAK
  logic [7:0]   tx_total_words;    // total 64-bit words to write
  logic [3:0]   tx_return;         // what to do after TX (0=idle, 1=adv_buf)
  logic         tx_buf;            // double-buffer toggle (0 or 1)

  // Found nonce capture
  logic         found_prev;
  logic         found_pending;
  logic [63:0]  found_nonce_reg;

  // Heartbeat timer
  logic [23:0]  hb_timer;
  logic         hb_pending;

  // Uptime counter (seconds, increments every 125M clocks)
  logic [26:0]  sec_prescaler;
  logic [31:0]  uptime_sec;

  // Captured framing_rdata for frame word processing
  logic [63:0]  captured_word;
  // Also save word 0 for ws_mac extraction
  logic [63:0]  saved_w0;

  // Init sequence step counter
  logic [1:0]   init_step;

  // ================================================================
  //  Uptime counter
  // ================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sec_prescaler <= '0;
      uptime_sec    <= '0;
    end else begin
      if (sec_prescaler >= 27'd124_999_999) begin
        sec_prescaler <= '0;
        uptime_sec    <= uptime_sec + 1;
      end else
        sec_prescaler <= sec_prescaler + 1;
    end
  end

  // ================================================================
  //  Heartbeat timer
  // ================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hb_timer   <= '0;
      hb_pending <= 1'b0;
    end else begin
      if (hb_timer >= HB_INTERVAL) begin
        hb_timer <= '0;
        if (mining_active) hb_pending <= 1'b1;
      end else
        hb_timer <= hb_timer + 1;
      if (state == S_TX_WR && tx_type == FT_HEARTBEAT && wcnt == 0)
        hb_pending <= 1'b0;
    end
  end

  // ================================================================
  //  Found edge detect
  // ================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      found_prev    <= 1'b0;
      found_pending <= 1'b0;
      found_nonce_reg <= '0;
    end else begin
      found_prev <= hh_found;
      if (hh_found && !found_prev) begin
        found_pending   <= 1'b1;
        found_nonce_reg <= hh_nonce_found;
      end
      if (state == S_TX_WR && tx_type == FT_NONCE && wcnt == 0)
        found_pending <= 1'b0;
    end
  end

  // ================================================================
  //  TX frame word generator (combinational)
  // ================================================================
  //
  // Ethernet header is 14 bytes = words 0-1 (partial).
  // Word 0: dst_mac[0:5] + src_mac[0:1] in LE byte order
  // Word 1: src_mac[2:5] + ethertype[0:1] + type + seq
  //
  // BRAM LE byte map: byte N -> word N/8, bits [(N%8)*8 +: 8]
  //   byte 0  = ws_mac[47:40]   -> w0[7:0]
  //   byte 1  = ws_mac[39:32]   -> w0[15:8]
  //   byte 2  = ws_mac[31:24]   -> w0[23:16]
  //   byte 3  = ws_mac[23:16]   -> w0[31:24]
  //   byte 4  = ws_mac[15:8]    -> w0[39:32]
  //   byte 5  = ws_mac[7:0]     -> w0[47:40]
  //   byte 6  = FPGA_MAC[47:40] -> w0[55:48]
  //   byte 7  = FPGA_MAC[39:32] -> w0[63:56]
  //   byte 8  = FPGA_MAC[31:24] -> w1[7:0]
  //   byte 9  = FPGA_MAC[23:16] -> w1[15:8]
  //   byte 10 = FPGA_MAC[15:8]  -> w1[23:16]
  //   byte 11 = FPGA_MAC[7:0]   -> w1[31:24]
  //   byte 12 = ethertype[15:8] -> w1[39:32]   (MSB first on wire)
  //   byte 13 = ethertype[7:0]  -> w1[47:40]
  //   byte 14 = frame_type      -> w1[55:48]
  //   byte 15 = frame_seq       -> w1[63:56]

  logic [63:0] tx_word;

  always_comb begin
    tx_word = '0;
    case (wcnt)
      8'd0: // Word 0: dst_mac + src_mac[0:1]
        tx_word = {FPGA_MAC[39:32], FPGA_MAC[47:40],
                   ws_mac[7:0], ws_mac[15:8], ws_mac[23:16],
                   ws_mac[31:24], ws_mac[39:32], ws_mac[47:40]};
      8'd1: // Word 1: src_mac[2:5] + ethertype + type + seq
        tx_word = {tx_seq, tx_type,
                   ETHERTYPE[7:0], ETHERTYPE[15:8],
                   FPGA_MAC[7:0], FPGA_MAC[15:8],
                   FPGA_MAC[23:16], FPGA_MAC[31:24]};
      8'd2: begin // Word 2: payload word 0
        case (tx_type)
          FT_NONCE:
            // bytes 16-23: found_nonce LE (byte 16 = nonce[7:0])
            tx_word = found_nonce_reg;
          FT_HEARTBEAT:
            // bytes 16-23: hash_count LE
            tx_word = hh_hash_count;
          FT_NAK:
            // byte 16: rejected seq, byte 17: error code 0x01 (bad FCS)
            tx_word = {48'd0, 8'h01, tx_seq};
          FT_ACK:
            // byte 16: echo seq
            tx_word = {56'd0, tx_seq};
          default:
            tx_word = '0;
        endcase
      end
      8'd3: begin // Word 3: payload word 1 (heartbeat only)
        // bytes 24-27: status(1) + uptime(3 of 4)
        // byte 24: {6'b0, found_pending, hh_busy}
        // bytes 25-28: uptime_sec LE
        tx_word = {24'd0, uptime_sec,
                   {6'b0, found_pending, hh_busy}};
      end
      default: tx_word = '0;
    endcase
  end

  // TX frame sizes (total bytes including eth header, excluding FCS)
  function automatic logic [7:0] tx_byte_len(input logic [7:0] ftype);
    case (ftype)
      FT_NONCE:     return 8'd24;  // 14+2+8
      FT_HEARTBEAT: return 8'd29;  // 14+2+8+1+4
      FT_NAK:       return 8'd18;  // 14+2+1+1
      FT_ACK:       return 8'd17;  // 14+2+1
      default:      return 8'd16;
    endcase
  endfunction

  function automatic logic [7:0] tx_word_count(input logic [7:0] ftype);
    case (ftype)
      FT_NONCE:     return 8'd3;  // words 0,1,2
      FT_HEARTBEAT: return 8'd4;  // words 0,1,2,3
      FT_NAK:       return 8'd3;
      FT_ACK:       return 8'd3;
      default:      return 8'd2;
    endcase
  endfunction

  // ================================================================
  //  Helper: bus address computation
  // ================================================================
  // RX buffer: bit16=1, [15:11]=buf, [10:3]=word, [2:0]=0
  function automatic logic [16:0] rx_addr(logic [4:0] buf_id, logic [7:0] word);
    return {1'b1, buf_id, word, 3'b000};
  endfunction

  // TX buffer: base 0x01000. addr[16:12]=00001, addr[11:3]=word_idx
  function automatic logic [16:0] tx_addr(logic [7:0] word);
    return {5'b00001, 4'b0, word[4:0], 3'b000};
  endfunction

  // rx_length_axis[N]: addr = 0x0C00 + N*8
  function automatic logic [16:0] len_addr(logic [4:0] buf_id);
    return {9'b0_0000_1100, buf_id, 3'b000};
  endfunction

  // Bus output helpers are inlined in the FSM as:
  //   BUS_READ(addr):  ce_d<=1; we_d<=0; core_lsu_addr<=addr;
  //   BUS_WRITE(addr,data): ce_d<=1; we_d<=1; core_lsu_addr<=addr; core_lsu_wdata<=data;
  //   BUS_IDLE: ce_d<=0; we_d<=0;

  // ================================================================
  //  Main FSM
  // ================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_INIT;
      init_step      <= 2'd0;
      ce_d           <= 1'b0;
      we_d           <= 1'b0;
      framing_sel    <= 1'b1;
      core_lsu_addr  <= '0;
      core_lsu_wdata <= '0;
      core_lsu_be    <= 8'hFF;
      hh_start       <= 1'b0;
      hh_stop        <= 1'b0;
      hh_mat_wr_en   <= 1'b0;
      hh_mid_state_1 <= '0;
      hh_mid_state_2 <= '0;
      hh_msg_block   <= '0;
      hh_target      <= '0;
      hh_nonce_start <= '0;
      hh_mat_wr_addr <= '0;
      hh_mat_wr_data <= '0;
      wcnt           <= '0;
      cur_buf        <= '0;
      frame_type     <= '0;
      frame_seq      <= '0;
      frame_fcs_err  <= 1'b0;
      frame_len      <= '0;
      got_hdr        <= 1'b0;
      got_mat0       <= 1'b0;
      got_mat1       <= 1'b0;
      mining_active  <= 1'b0;
      mat_sub        <= '0;
      mat_abs_row    <= '0;
      mat_row_offset <= '0;
      mat_row_acc    <= '0;
      ws_mac         <= 48'hFF_FF_FF_FF_FF_FF;
      tx_type        <= '0;
      tx_seq         <= '0;
      tx_total_words <= '0;
      tx_return      <= '0;
      tx_buf         <= 1'b0;
      captured_word  <= '0;
      saved_w0       <= '0;
      led_mining     <= 1'b0;
      led_found      <= 1'b0;
    end else begin
      // Defaults: de-assert one-shot signals
      hh_start     <= 1'b0;
      hh_stop      <= 1'b0;
      hh_mat_wr_en <= 1'b0;

      led_mining <= mining_active;
      led_found  <= found_pending;

      case (state)
        // ============================================================
        // Init: write MAC address, lastbuf, and promiscuous mode to framing_top
        // so the MAC accepts frames addressed to FPGA_MAC.
        //
        // Step 0: write mac_address[31:0]         -> addr 0x0800 (reg 0)
        // Step 1: write mac_address[47:32]+flags  -> addr 0x0808 (reg 1)
        //         (promiscuous=1 as fallback, irq_en=0)
        // Step 2: write lastbuf=31                -> addr 0x0828 (reg 5)
        S_INIT: begin
          ce_d <= 1'b1; we_d <= 1'b1;
          case (init_step)
            2'd0: begin
              // mac_address[31:0] = FPGA_MAC[31:0]
              // FPGA_MAC = 48'h02_00_00_4B_41_31
              // mac_address[31:0] = 32'h004B4131
              core_lsu_addr  <= 17'h00800;
              core_lsu_wdata <= {32'd0, FPGA_MAC[31:0]};
              init_step      <= 2'd1;
            end
            2'd1: begin
              // {irq_en, promiscuous, spare[3:0], loopback, cooked, mac_address[47:32]}
              // = wdata[23:0]. Set promiscuous=1 (bit 22), mac[47:32]=FPGA_MAC[47:32]
              core_lsu_addr  <= 17'h00808;
              core_lsu_wdata <= {40'd0,
                                 1'b0,              // [23] irq_en
                                 1'b1,              // [22] promiscuous
                                 4'b0,              // [21:18] spare
                                 1'b0,              // [17] loopback
                                 1'b0,              // [16] cooked
                                 FPGA_MAC[47:32]};  // [15:0] mac_address[47:32]
              init_step      <= 2'd2;
            end
            2'd2: begin
              // lastbuf = 31
              core_lsu_addr  <= 17'h00828;
              core_lsu_wdata <= {59'd0, 5'd31};
              init_step      <= 2'd3;
            end
            default: begin
              ce_d <= 1'b0; we_d <= 1'b0;
              state <= S_IDLE;
            end
          endcase
        end

        // ============================================================
        S_IDLE: begin
          ce_d <= 1'b0; we_d <= 1'b0;
          if (found_pending) begin
            tx_type        <= FT_NONCE;
            tx_seq         <= '0;
            tx_total_words <= tx_word_count(FT_NONCE);
            tx_return      <= 4'd0;
            wcnt           <= '0;
            state          <= S_TX_WR;
          end else if (hb_pending) begin
            tx_type        <= FT_HEARTBEAT;
            tx_seq         <= '0;
            tx_total_words <= tx_word_count(FT_HEARTBEAT);
            tx_return      <= 4'd0;
            wcnt           <= '0;
            state          <= S_TX_WR;
          end else begin
            // Poll for RX frame
            ce_d <= 1'b1; we_d <= 1'b0;
            core_lsu_addr <= 17'h00830;
            state <= S_POLL_WAIT;
          end
        end

        // ---- Poll for available RX frame ----
        // Keep ce_d high so ce_d_dly is still 1 when S_POLL_DONE reads framing_rdata
        S_POLL_WAIT: begin
          state <= S_POLL_DONE;
        end

        S_POLL_DONE: begin
          if (framing_rdata[15]) begin
            cur_buf <= framing_rdata[4:0];
            ce_d <= 1'b1; we_d <= 1'b0;
            core_lsu_addr <= len_addr(framing_rdata[4:0]);
            state <= S_LEN_WAIT;
          end else
            state <= S_IDLE;
        end

        // ---- Read frame length + FCS status ----
        S_LEN_WAIT: begin
          state <= S_LEN_DONE;
        end

        S_LEN_DONE: begin
          frame_len     <= framing_rdata[10:0];
          frame_fcs_err <= framing_rdata[11];
          if (framing_rdata[11]) begin
            // Bad FCS — NAK then advance
            tx_type <= FT_NAK; tx_seq <= 8'hFF;
            tx_total_words <= tx_word_count(FT_NAK);
            tx_return <= 4'd1; wcnt <= '0;
            state <= S_TX_WR;
          end else begin
            wcnt <= '0;
            ce_d <= 1'b1; we_d <= 1'b0;
            core_lsu_addr <= rx_addr(cur_buf, 8'd0);
            state <= S_FRAME_WAIT;
          end
        end

        // ---- Sequential frame read ----
        S_FRAME_WAIT: begin
          state <= S_FRAME_PROC;
        end

        S_FRAME_PROC: begin
          captured_word <= framing_rdata;

          case (frame_type)
            // ---- Header words (type not yet known) ----
            8'h00: begin
              if (wcnt == 8'd0) begin
                saved_w0 <= framing_rdata;
                wcnt <= 8'd1;
                ce_d <= 1'b1; we_d <= 1'b0;
                core_lsu_addr <= rx_addr(cur_buf, 8'd1);
                state <= S_FRAME_WAIT;
              end else begin
                frame_type <= framing_rdata[55:48];
                frame_seq  <= framing_rdata[63:56];
                ws_mac[47:40] <= saved_w0[55:48];
                ws_mac[39:32] <= saved_w0[63:56];
                ws_mac[31:24] <= framing_rdata[7:0];
                ws_mac[23:16] <= framing_rdata[15:8];
                ws_mac[15:8]  <= framing_rdata[23:16];
                ws_mac[7:0]   <= framing_rdata[31:24];

                if ({framing_rdata[39:32], framing_rdata[47:40]} != ETHERTYPE) begin
                  state <= S_ADV_BUF;
                end else if (framing_rdata[55:48] == FT_CONFIG_HDR) begin
                  if (mining_active) begin
                    hh_stop <= 1'b1; mining_active <= 1'b0;
                  end
                  got_hdr <= 1'b0; got_mat0 <= 1'b0; got_mat1 <= 1'b0;
                  wcnt <= W_MS1_START;
                  ce_d <= 1'b1; we_d <= 1'b0;
                  core_lsu_addr <= rx_addr(cur_buf, W_MS1_START);
                  state <= S_FRAME_WAIT;
                end else if (framing_rdata[55:48] == FT_CONFIG_MAT) begin
                  wcnt <= W_ROWOFF;
                  ce_d <= 1'b1; we_d <= 1'b0;
                  core_lsu_addr <= rx_addr(cur_buf, W_ROWOFF);
                  state <= S_FRAME_WAIT;
                end else
                  state <= S_ADV_BUF;
              end
            end

            // ---- CONFIG_HDR payload ----
            FT_CONFIG_HDR: begin
              if (wcnt >= W_MS1_START && wcnt <= W_MS1_END)
                hh_mid_state_1[(wcnt - W_MS1_START)*64 +: 64] <= framing_rdata;
              if (wcnt >= W_MS2_START && wcnt <= W_MS2_END)
                hh_mid_state_2[(wcnt - W_MS2_START)*64 +: 64] <= framing_rdata;
              if (wcnt >= W_MSG_START && wcnt <= W_MSG_END)
                hh_msg_block[(wcnt - W_MSG_START)*64 +: 64] <= framing_rdata;
              if (wcnt >= W_TGT_START && wcnt <= W_TGT_END)
                hh_target[(wcnt - W_TGT_START)*64 +: 64] <= framing_rdata;
              if (wcnt == W_NONCE_W)
                hh_nonce_start <= framing_rdata;

              if (wcnt < W_CFG_LAST) begin
                wcnt <= wcnt + 1;
                ce_d <= 1'b1; we_d <= 1'b0;
                core_lsu_addr <= rx_addr(cur_buf, wcnt + 1);
                state <= S_FRAME_WAIT;
              end else begin
                got_hdr <= 1'b1;
                tx_type <= FT_ACK; tx_seq <= frame_seq;
                tx_total_words <= tx_word_count(FT_ACK);
                tx_return <= 4'd1; wcnt <= '0;
                state <= S_TX_WR;
              end
            end

            // ---- CONFIG_MAT: row_offset then matrix data ----
            FT_CONFIG_MAT: begin
              if (wcnt == W_ROWOFF) begin
                mat_row_offset <= framing_rdata[5:0];
                mat_sub <= 2'd0; mat_abs_row <= framing_rdata[5:0];
                mat_row_acc <= '0;
                wcnt <= W_MDAT_START;
                ce_d <= 1'b1; we_d <= 1'b0;
                core_lsu_addr <= rx_addr(cur_buf, W_MDAT_START);
                state <= S_FRAME_WAIT;
              end else begin
                mat_row_acc[mat_sub*64 +: 64] <= framing_rdata;
                if (mat_sub == 2'd3) begin
                  hh_mat_wr_addr <= mat_abs_row;
                  hh_mat_wr_data <= {framing_rdata, mat_row_acc[191:0]};
                  state <= S_MAT_WR;
                end else if (wcnt < W_MDAT_END) begin
                  mat_sub <= mat_sub + 1;
                  wcnt <= wcnt + 1;
                  ce_d <= 1'b1; we_d <= 1'b0;
                  core_lsu_addr <= rx_addr(cur_buf, wcnt + 1);
                  state <= S_FRAME_WAIT;
                end else
                  state <= S_ADV_BUF;
              end
            end

            default: state <= S_ADV_BUF;
          endcase
        end

        // ---- Matrix row write ----
        S_MAT_WR: begin
          hh_mat_wr_en <= 1'b1;
          mat_sub <= 2'd0; mat_row_acc <= '0;
          mat_abs_row <= mat_abs_row + 1;
          if (wcnt < W_MDAT_END) begin
            wcnt <= wcnt + 1;
            ce_d <= 1'b1; we_d <= 1'b0;
            core_lsu_addr <= rx_addr(cur_buf, wcnt + 1);
            state <= S_FRAME_WAIT;
          end else begin
            if (mat_row_offset == 6'd0) got_mat0 <= 1'b1;
            else                        got_mat1 <= 1'b1;
            tx_type <= FT_ACK; tx_seq <= frame_seq;
            tx_total_words <= tx_word_count(FT_ACK);
            tx_return <= 4'd1; wcnt <= '0;
            state <= S_TX_WR;
          end
        end

        // ---- TX: write frame words to TX BRAM (double-buffered) ----
        S_TX_WR: begin
          ce_d <= 1'b1; we_d <= 1'b1;
          core_lsu_addr <= {4'b0, 1'b1, tx_buf, 4'b0, wcnt[3:0], 3'b000};
          core_lsu_wdata <= tx_word;
          if (wcnt + 1 >= tx_total_words) begin
            wcnt <= '0; state <= S_TX_WAIT;
          end else begin
            wcnt <= wcnt + 1; state <= S_TX_WR;
          end
        end

        // ---- TX: wait for previous TX to complete before triggering ----
        // (writing register 2 while MAC is active clobbers tx_enable_dly)
        S_TX_WAIT: begin
          ce_d <= 1'b1; we_d <= 1'b0;
          core_lsu_addr <= 17'h00810;   // TX status register
          state <= S_TX_WAIT_DONE;
        end

        S_TX_WAIT_DONE: begin
          if (framing_rdata[31]) begin  // tx_busy still set
            ce_d <= 1'b1; we_d <= 1'b0;
            core_lsu_addr <= 17'h00810;
            state <= S_TX_WAIT;
          end else begin
            state <= S_TX_GO;
          end
        end

        // ---- TX: trigger transmission ----
        S_TX_GO: begin
          ce_d <= 1'b1; we_d <= 1'b1;
          core_lsu_addr <= 17'h00810;
          core_lsu_wdata <= {52'd0, tx_buf, 3'd0, tx_byte_len(tx_type)};
          tx_buf <= ~tx_buf;   // toggle for next frame
          if (tx_return == 4'd1) state <= S_ADV_BUF;
          else                   state <= S_DONE;
        end

        // ---- Advance RX buffer pointer ----
        S_ADV_BUF: begin
          ce_d <= 1'b1; we_d <= 1'b1;
          core_lsu_addr <= 17'h00830;
          core_lsu_wdata <= {59'd0, cur_buf + 5'd1};
          frame_type <= '0;
          state <= S_DONE;
        end

        // ---- Post-processing ----
        S_DONE: begin
          ce_d <= 1'b0; we_d <= 1'b0;
          if (got_hdr && got_mat0 && got_mat1 && !mining_active) begin
            hh_start <= 1'b1; mining_active <= 1'b1;
          end
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // Debug port assignments
  assign dbg_state      = state;
  assign dbg_init_step  = init_step;
  assign dbg_frame_type = frame_type;
  assign dbg_wcnt       = wcnt;
  assign dbg_cur_buf    = cur_buf;
  assign dbg_flags      = {got_hdr, got_mat0, got_mat1, mining_active};

endmodule

`default_nettype wire
