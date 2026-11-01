// heavyhash_lanes.sv -- NUM_LANES HeavyHash lanes, each on its own regional
// clock buffer, configured over a narrow chain instead of a broadcast.
//
// The same interface as heavyhash_multi.sv (minus its phase clocks), so
// mine_ctrl.sv drives it unchanged.  What differs is the physical shape:
//
//   * Each lane is clocked through its own BUFHCE from clk.  A BUFHCE drives
//     exactly one clock region, and nextpnr (BUFHCE in
//     constrain_regional_clock_sinks) keeps everything a placed BUFHCE clocks
//     inside that region: one LOC per lane in the XDC is the lane's floorplan.
//     All BUFHCEs hang off clk's BUFG, so the lanes and the controller are one
//     synchronous clock; there is no clock crossing.
//
//   * Configuration reaches the lanes as 64-bit words on a chain, lane to
//     lane, not as ~4.9k parallel bits fanned out to every lane (which made
//     ~60k long nets for 12 lanes).  A serializer next to mine_ctrl turns its
//     parallel registers into bus words:
//
//       CFG  idx 0..71   mid_state_1 (0-24), mid_state_2 (25-49),
//                         msg_block (50-66), target (67-70), nonce_start (71)
//       MATW idx[1:0]    one 64-bit word of a matrix row
//       MATC idx[5:0]    commit the row assembled from the MATW words
//       CTL  idx[0]      start, idx[1] stop
//
//     A job is mine_ctrl's CONFIG_MAT rows (each forwarded as 4 MATW + MATC as
//     it arrives) and then, on hh_start, the 72 CFG words followed by CTL
//     start: 73 cycles before the lanes start, against 36 per hash.  The bus
//     goes through every lane in turn, one register per lane, so a lane sees
//     the words in the order they were sent and the start after its config.
//
//   * Results come back the same way: found, the found nonce and the summed
//     hash count, chained lane to lane (lane NUM_LANES-1 first, lane 0 last,
//     next to the controller).  A lane earlier in that chain wins a tie.

`default_nettype none

module heavyhash_lanes
  import keccak_pkg::*,
         heavyhash_pkg::*;
#(
  parameter int unsigned NUM_LANES = 4
)
(
  input  logic          clk,
  input  logic          rst_n,

  input  logic          start,
  input  logic          stop,
  output logic          busy,
  output logic          found,

  input  logic [1599:0] mid_state_1,
  input  logic [1599:0] mid_state_2,
  input  logic [RATE-1:0] msg_block,
  input  logic [255:0]  target,
  input  logic [63:0]   nonce_start,

  output logic [63:0]   nonce_found,
  output logic [63:0]   hash_count,

  input  logic          mat_wr_en,
  input  logic [5:0]    mat_wr_addr,
  input  logic [255:0]  mat_wr_data
);

  localparam logic [1:0] CMD_CFG = 2'd0, CMD_MATW = 2'd1, CMD_MATC = 2'd2, CMD_CTL = 2'd3;
  localparam int unsigned CFG_WORDS = 72;

  // bus word: {valid, cmd[1:0], idx[6:0], data[63:0]}
  localparam int unsigned BW = 74;
  function automatic logic [BW-1:0] word(input logic [1:0] cmd, input logic [6:0] idx, input logic [63:0] data);
    word = {1'b1, cmd, idx, data};
  endfunction

  // ================================================================
  //  Serializer (controller side)
  // ================================================================
  logic         row_pend;          // a matrix row waiting to go out
  logic [5:0]   row_addr;
  logic [255:0] row_data;
  logic [2:0]   row_step;          // 0-3 MATW, 4 MATC
  logic         start_pend, stop_pend, cfg_run;
  logic [6:0]   cfg_idx;
  logic [BW-1:0] ser;

  function automatic logic [63:0] cfg_word(input logic [6:0] i);
    if (i < 7'd25)      cfg_word = mid_state_1[i*64 +: 64];
    else if (i < 7'd50) cfg_word = mid_state_2[(i - 7'd25)*64 +: 64];
    else if (i < 7'd67) cfg_word = msg_block[(i - 7'd50)*64 +: 64];
    else if (i < 7'd71) cfg_word = target[(i - 7'd67)*64 +: 64];
    else                cfg_word = nonce_start;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row_pend   <= 1'b0;
      row_step   <= '0;
      start_pend <= 1'b0;
      stop_pend  <= 1'b0;
      cfg_run    <= 1'b0;
      cfg_idx    <= '0;
      ser        <= '0;
      row_addr   <= '0;
      row_data   <= '0;
    end else begin
      ser <= '0;
      if (mat_wr_en) begin
        // mine_ctrl writes a row at most every ~9 cycles; one takes 5 here
        row_pend <= 1'b1;
        row_addr <= mat_wr_addr;
        row_data <= mat_wr_data;
        row_step <= '0;
      end
      if (start) start_pend <= 1'b1;
      if (stop)  stop_pend  <= 1'b1;

      if (stop_pend) begin
        // a stop goes first: it ends the old job before the new one's words
        ser <= word(CMD_CTL, 7'd2, 64'd0);
        stop_pend <= 1'b0;
      end else if (row_pend && !mat_wr_en) begin
        if (row_step < 3'd4) begin
          ser <= word(CMD_MATW, {5'd0, row_step[1:0]}, row_data[row_step[1:0]*64 +: 64]);
          row_step <= row_step + 3'd1;
        end else begin
          ser <= word(CMD_MATC, {1'b0, row_addr}, 64'd0);
          row_pend <= 1'b0;
        end
      end else if (cfg_run) begin
        if (cfg_idx < 7'(CFG_WORDS)) begin
          ser <= word(CMD_CFG, cfg_idx, cfg_word(cfg_idx));
          cfg_idx <= cfg_idx + 7'd1;
        end else begin
          ser <= word(CMD_CTL, 7'd1, 64'd0);
          cfg_run <= 1'b0;
        end
      end else if (start_pend) begin
        start_pend <= 1'b0;
        cfg_run    <= 1'b1;
        cfg_idx    <= '0;
      end
    end
  end

  // ================================================================
  //  Lanes
  // ================================================================
  logic [BW-1:0]        bus   [NUM_LANES+1];   // bus[i] into lane i
  logic [NUM_LANES:0]   r_found, r_busy;       // index i: out of lane i (NUM_LANES: none)
  logic [63:0]          r_nonce  [NUM_LANES+1];
  logic [63:0]          r_count  [NUM_LANES+1];

  assign bus[0]             = ser;
  assign r_found[NUM_LANES] = 1'b0;
  assign r_busy[NUM_LANES]  = 1'b0;
  assign r_nonce[NUM_LANES] = '0;
  assign r_count[NUM_LANES] = '0;

  genvar g;
  generate
    for (g = 0; g < NUM_LANES; g++) begin : gen_lane
      // ---- the lane's clock: its own BUFHCE, so its own clock region ----
      wire lane_clk;
`ifdef SYNTHESIS
      BUFHCE #(.CE_TYPE("SYNC"), .INIT_OUT(0)) u_bufh (.I(clk), .CE(1'b1), .O(lane_clk));
`else
      assign lane_clk = clk;
`endif

      logic [2:0] rst_sr;
      always_ff @(posedge lane_clk or negedge rst_n)
        if (!rst_n) rst_sr <= 3'b000;
        else        rst_sr <= {rst_sr[1:0], 1'b1};
      wire lane_rst_n = rst_sr[2];

      // ---- config chain: this lane's copy of the bus, passed on ----
      logic [BW-1:0] b;
      always_ff @(posedge lane_clk or negedge lane_rst_n)
        if (!lane_rst_n) b <= '0;
        else             b <= bus[g];
      assign bus[g+1] = b;

      // One register per 64-bit config word, each with its own decoded
      // enable: FDRE/CE, no LUT per bit (an indexed part-select write into
      // the wide vectors cost a LUT mux on every one of the ~4.9k bits).
      wire        b_valid = b[73];
      wire [1:0]  b_cmd   = b[72:71];
      wire [6:0]  b_idx   = b[70:64];
      wire [63:0] b_data  = b[63:0];

      wire cfg_wr  = b_valid && b_cmd == CMD_CFG;
      wire matw_wr = b_valid && b_cmd == CMD_MATW;
      // packed, not arrays: 72 x 64 is over the register-array size limit
      logic [CFG_WORDS*64-1:0] cfg_q;
      logic [255:0]            row_q;
      for (genvar w = 0; w < CFG_WORDS; w++) begin : gen_cfg
        logic [63:0] q;
        always_ff @(posedge lane_clk)
          if (cfg_wr && b_idx == 7'(w)) q <= b_data;
        assign cfg_q[w*64 +: 64] = q;
      end
      for (genvar w = 0; w < 4; w++) begin : gen_row
        logic [63:0] q;
        always_ff @(posedge lane_clk)
          if (matw_wr && b_idx[1:0] == 2'(w)) q <= b_data;
        assign row_q[w*64 +: 64] = q;
      end

      logic [1599:0]   lc_mid_state_1, lc_mid_state_2;
      logic [RATE-1:0] lc_msg_block;
      logic [255:0]    lc_target;
      logic [63:0]     lc_nonce_start;
      logic [255:0]    lc_row;
      assign lc_mid_state_1 = cfg_q[0*64 +: 1600];
      assign lc_mid_state_2 = cfg_q[25*64 +: 1600];
      assign lc_msg_block   = cfg_q[50*64 +: RATE];
      assign lc_target      = cfg_q[67*64 +: 256];
      assign lc_row         = row_q;
      assign lc_nonce_start = cfg_q[71*64 +: 64] + 64'(g);

      logic       lc_start, lc_stop, lc_mat_wr;
      logic [5:0] lc_mat_addr;
      always_ff @(posedge lane_clk) begin
        lc_start  <= b_valid && b_cmd == CMD_CTL && b_idx[0];
        lc_stop   <= b_valid && b_cmd == CMD_CTL && b_idx[1];
        lc_mat_wr <= b_valid && b_cmd == CMD_MATC;
        if (b_valid && b_cmd == CMD_MATC) lc_mat_addr <= b_idx[5:0];
      end

      logic        pipe_busy, pipe_found;
      logic [63:0] pipe_nonce, pipe_count;

      heavyhash_pipeline #(.NONCE_STEP(NUM_LANES)) u_pipe (
        .clk         ( lane_clk       ),
        .rst_n       ( lane_rst_n     ),
        .start       ( lc_start       ),
        .stop        ( lc_stop        ),
        .busy        ( pipe_busy      ),
        .found       ( pipe_found     ),
        .mid_state_1 ( lc_mid_state_1 ),
        .mid_state_2 ( lc_mid_state_2 ),
        .msg_block   ( lc_msg_block   ),
        .target      ( lc_target      ),
        .nonce_start ( lc_nonce_start ),
        .nonce_found ( pipe_nonce     ),
        .hash_count  ( pipe_count     ),
        .mat_wr_en   ( lc_mat_wr      ),
        .mat_wr_addr ( lc_mat_addr    ),
        .mat_wr_data ( lc_row         )
      );

      // ---- result chain: from lane g+1, through this lane, to lane g-1 ----
      logic        q_found, q_busy;
      logic [63:0] q_nonce, q_count;
      always_ff @(posedge lane_clk or negedge lane_rst_n) begin
        if (!lane_rst_n) begin
          q_found <= 1'b0;
          q_busy  <= 1'b0;
          q_nonce <= '0;
          q_count <= '0;
        end else begin
          q_found <= pipe_found | r_found[g+1];
          q_busy  <= pipe_busy  | r_busy[g+1];
          q_nonce <= pipe_found ? pipe_nonce : r_nonce[g+1];
          q_count <= pipe_count + r_count[g+1];
        end
      end
      assign r_found[g] = q_found;
      assign r_busy[g]  = q_busy;
      assign r_nonce[g] = q_nonce;
      assign r_count[g] = q_count;
    end
  endgenerate

  assign found       = r_found[0];
  assign busy        = r_busy[0];
  assign nonce_found = r_nonce[0];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) hash_count <= '0;
    else        hash_count <= r_count[0];

endmodule

`default_nettype wire
