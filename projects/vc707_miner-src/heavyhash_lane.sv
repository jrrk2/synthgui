// heavyhash_lane.sv -- one HeavyHash lane as a physical-hierarchy block.
//
// heavyhash_lanes.sv instantiates NUM_LANES of these, each on its own BUFHCE.
// Everything that differs between lanes is a port, not a parameter or a
// generate index: the lane's number (lane_id, for its nonce offset) comes in
// as a constant from the instantiating module.  So every lane is the same
// netlist -- the open flow maps this module ONCE (verilator --map-only-output
// --map-only-no-iobuf, one ABC run) and splices that one mapped netlist in
// for every instance, so all lanes carry the same cell names behind a
// per-lane prefix.  That is what lets one lane's placement be stamped onto
// the others (the cell names, not a graph match, say which cell is which).
//
// Ports, all on the lane's own clock:
//   bus_in / bus_out    the configuration chain (see heavyhash_lanes.sv)
//   r_*_in / r_*_out    the result chain: found, busy, found nonce, summed count

`default_nettype none

module heavyhash_lane
  import keccak_pkg::*;
#(
  parameter int unsigned NONCE_STEP = 1
)
(
  input  logic        clk,          // this lane's regional clock
  input  logic        rst_n,        // asynchronous; synchronised here
  input  logic [5:0]  lane_id,      // constant per instance

  input  logic [73:0] bus_in,
  output logic [73:0] bus_out,

  input  logic        r_found_in,
  input  logic        r_busy_in,
  input  logic [63:0] r_nonce_in,
  input  logic [63:0] r_count_in,
  output logic        r_found_out,
  output logic        r_busy_out,
  output logic [63:0] r_nonce_out,
  output logic [63:0] r_count_out
);

  // the bus format of heavyhash_lanes.sv: {valid, cmd[1:0], idx[6:0], data[63:0]}
  localparam logic [1:0] CMD_CFG = 2'd0, CMD_MATW = 2'd1, CMD_MATC = 2'd2, CMD_CTL = 2'd3;
  localparam int unsigned CFG_WORDS = 72;

  logic [2:0] rst_sr;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rst_sr <= 3'b000;
    else        rst_sr <= {rst_sr[1:0], 1'b1};
  wire lane_rst_n = rst_sr[2];

  // ---- config chain: this lane's copy of the bus, passed on ----
  logic [73:0] b;
  always_ff @(posedge clk or negedge lane_rst_n)
    if (!lane_rst_n) b <= '0;
    else             b <= bus_in;
  assign bus_out = b;

  wire        b_valid = b[73];
  wire [1:0]  b_cmd   = b[72:71];
  wire [6:0]  b_idx   = b[70:64];
  wire [63:0] b_data  = b[63:0];

  // One register per 64-bit config word, each with its own decoded enable:
  // FDRE/CE, no LUT per bit (an indexed part-select write into the wide
  // vectors cost a LUT mux on every one of the ~4.9k bits).  Packed, not an
  // array: 72 x 64 bits is over the register-array size limit.
  wire cfg_wr  = b_valid && b_cmd == CMD_CFG;
  wire matw_wr = b_valid && b_cmd == CMD_MATW;
  logic [CFG_WORDS*64-1:0] cfg_q;
  logic [255:0]            row_q;
  for (genvar w = 0; w < CFG_WORDS; w++) begin : gen_cfg
    logic [63:0] q;
    always_ff @(posedge clk)
      if (cfg_wr && b_idx == 7'(w)) q <= b_data;
    assign cfg_q[w*64 +: 64] = q;
  end
  for (genvar w = 0; w < 4; w++) begin : gen_row
    logic [63:0] q;
    always_ff @(posedge clk)
      if (matw_wr && b_idx[1:0] == 2'(w)) q <= b_data;
    assign row_q[w*64 +: 64] = q;
  end

  logic       lc_start, lc_stop, lc_mat_wr;
  logic [5:0] lc_mat_addr;
  always_ff @(posedge clk) begin
    lc_start  <= b_valid && b_cmd == CMD_CTL && b_idx[0];
    lc_stop   <= b_valid && b_cmd == CMD_CTL && b_idx[1];
    lc_mat_wr <= b_valid && b_cmd == CMD_MATC;
    if (b_valid && b_cmd == CMD_MATC) lc_mat_addr <= b_idx[5:0];
  end

  logic        pipe_busy, pipe_found;
  logic [63:0] pipe_nonce, pipe_count;

  heavyhash_pipeline #(.NONCE_STEP(NONCE_STEP)) u_pipe (
    .clk         ( clk                              ),
    .rst_n       ( lane_rst_n                       ),
    .start       ( lc_start                         ),
    .stop        ( lc_stop                          ),
    .busy        ( pipe_busy                        ),
    .found       ( pipe_found                       ),
    .mid_state_1 ( cfg_q[0*64 +: 1600]              ),
    .mid_state_2 ( cfg_q[25*64 +: 1600]             ),
    .msg_block   ( cfg_q[50*64 +: RATE]             ),
    .target      ( cfg_q[67*64 +: 256]              ),
    .nonce_start ( cfg_q[71*64 +: 64] + 64'(lane_id) ),
    .nonce_found ( pipe_nonce                       ),
    .hash_count  ( pipe_count                       ),
    .mat_wr_en   ( lc_mat_wr                        ),
    .mat_wr_addr ( lc_mat_addr                      ),
    .mat_wr_data ( row_q                            )
  );

  // ---- result chain: from the next lane, through this one ----
  always_ff @(posedge clk or negedge lane_rst_n) begin
    if (!lane_rst_n) begin
      r_found_out <= 1'b0;
      r_busy_out  <= 1'b0;
      r_nonce_out <= '0;
      r_count_out <= '0;
    end else begin
      r_found_out <= pipe_found | r_found_in;
      r_busy_out  <= pipe_busy  | r_busy_in;
      r_nonce_out <= pipe_found ? pipe_nonce : r_nonce_in;
      r_count_out <= pipe_count + r_count_in;
    end
  end

endmodule

`default_nettype wire
