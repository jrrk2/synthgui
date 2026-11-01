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
//
//   * A lane is heavyhash_lane.sv, identical for every instance (its number
//     is a constant port), so the open flow maps it once and reuses that
//     mapped netlist, and one placement, for every lane.

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
  // Packed: these connect lane instance outputs, and an unpacked array driven
  // only through instance ports is taken for a memory by the synthesis branch,
  // which then drops those connections (heavyhash_lane is mapped on its own and
  // instantiated as a black box).  Index i: into lane i (bus), out of lane i
  // (results); NUM_LANES is the end of each chain.
  logic [NUM_LANES:0][BW-1:0] bus;
  logic [NUM_LANES:0]         r_found, r_busy;
  logic [NUM_LANES:0][63:0]   r_nonce, r_count;

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

      heavyhash_lane #(.NONCE_STEP(NUM_LANES)) u_lane (
        .clk         ( lane_clk     ),
        .rst_n       ( rst_n        ),
        .lane_id     ( 6'(g)        ),
        .bus_in      ( bus[g]       ),
        .bus_out     ( bus[g+1]     ),
        .r_found_in  ( r_found[g+1] ),
        .r_busy_in   ( r_busy[g+1]  ),
        .r_nonce_in  ( r_nonce[g+1] ),
        .r_count_in  ( r_count[g+1] ),
        .r_found_out ( r_found[g]   ),
        .r_busy_out  ( r_busy[g]    ),
        .r_nonce_out ( r_nonce[g]   ),
        .r_count_out ( r_count[g]   )
      );
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
