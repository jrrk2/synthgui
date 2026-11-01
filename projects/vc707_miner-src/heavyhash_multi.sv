// heavyhash_multi.sv — Multi-lane HeavyHash mining wrapper with phase-spread clocking
//
// 12 lanes across 4 phase-shifted 125 MHz clocks (0°, 90°, 180°, 270°).
// Three lanes per phase clock (posedge only), giving 4 evenly-spaced
// switching events 90° (2 ns) apart per period, with 3 pipelines
// sharing each switching edge.
//
// Lane  Phase-clk  Phase    Lane  Phase-clk  Phase    Lane  Phase-clk  Phase
//  0     [0]  0°              4     [0]  0°              8     [0]  0°
//  1     [1]  90°             5     [1]  90°             9     [1]  90°
//  2     [2]  180°            6     [2]  180°           10     [2]  180°
//  3     [3]  270°            7     [3]  270°           11     [3]  270°
//
// All clocks are mesochronous (same frequency, known phase offsets from
// a single MMCM).  Config signals are quasi-static (stable before start),
// so a single register stage provides clean CDC.  Outputs are synced
// back to the base clock (phase_clk[0]) with 2FF synchronizers.

module heavyhash_multi
  import keccak_pkg::*,
         heavyhash_pkg::*;
#(
  parameter int unsigned NUM_LANES = 12
)
(
  input  logic          clk,           // base clock (phase_clk[0], 0°)
  input  logic          rst_n,
  input  logic [3:0]    phase_clk,     // 4 phase-shifted clocks (0°, 90°, 180°, 270°)

  // Control (base clock domain)
  input  logic          start,
  input  logic          stop,
  output logic          busy,
  output logic          found,

  // Configuration (base clock domain, stable before start)
  input  logic [1599:0] mid_state_1,
  input  logic [1599:0] mid_state_2,
  input  logic [RATE-1:0] msg_block,
  input  logic [255:0]  target,
  input  logic [63:0]   nonce_start,

  // Results (base clock domain)
  output logic [63:0]   nonce_found,
  output logic [63:0]   hash_count,

  // Matrix BRAM write port (base clock domain)
  input  logic          mat_wr_en,
  input  logic [5:0]    mat_wr_addr,
  input  logic [255:0]  mat_wr_data
);

  // ================================================================
  //  Input pipeline registers (base clock domain)
  //  Breaks long routing from mine_ctrl to pipeline area.
  // ================================================================
  logic [1599:0]   mid_state_1_r;
  logic [1599:0]   mid_state_2_r;
  logic [RATE-1:0] msg_block_r;
  logic [255:0]    target_r;
  logic [63:0]     nonce_start_r;
  logic            start_r;
  logic            stop_r;
  logic            mat_wr_en_r;
  logic [5:0]      mat_wr_addr_r;
  logic [255:0]    mat_wr_data_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_r     <= 1'b0;
      stop_r      <= 1'b0;
      mat_wr_en_r <= 1'b0;
    end else begin
      mid_state_1_r <= mid_state_1;
      mid_state_2_r <= mid_state_2;
      msg_block_r   <= msg_block;
      target_r      <= target;
      nonce_start_r <= nonce_start;
      start_r       <= start;
      stop_r        <= stop;
      mat_wr_en_r   <= mat_wr_en;
      mat_wr_addr_r <= mat_wr_addr;
      mat_wr_data_r <= mat_wr_data;
    end
  end

  // ================================================================
  //  Per-lane clock assignment
  //  Three lanes per phase clock, posedge only.
  //  lane_clk[g] = phase_clk[g % 4]
  // ================================================================
  wire [NUM_LANES-1:0] lane_clk;

  genvar gc;
  generate
    for (gc = 0; gc < NUM_LANES; gc++) begin : gen_clk
      assign lane_clk[gc] = phase_clk[gc % 4];
    end
  endgenerate

  // ================================================================
  //  Per-lane: reset sync, CDC, pipeline, output sync
  // ================================================================
  logic [NUM_LANES-1:0] lane_found_sync;
  logic [NUM_LANES-1:0] lane_busy_sync;
  logic [63:0]          lane_nonce_raw  [NUM_LANES];
  logic [63:0]          lane_hcount_raw [NUM_LANES];

  genvar g;
  generate
    for (g = 0; g < NUM_LANES; g++) begin : gen_lane

      // ---- Reset synchronizer for lane clock domain ----
      logic [2:0] lane_rst_sr;
      wire        lane_rst_n = lane_rst_sr[2];

      always_ff @(posedge lane_clk[g] or negedge rst_n) begin
        if (!rst_n)
          lane_rst_sr <= 3'b000;
        else
          lane_rst_sr <= {lane_rst_sr[1:0], 1'b1};
      end

      // ---- CDC: base clock → lane clock (mesochronous, 1 stage) ----
      // Config signals are quasi-static (stable well before start),
      // so a single register provides clean capture in the lane domain.
      // Also serves as per-lane replication, keeping routes local.

      logic [1599:0]   lc_mid_state_1;
      logic [1599:0]   lc_mid_state_2;
      logic [RATE-1:0] lc_msg_block;
      logic [255:0]    lc_target;
      logic [63:0]     lc_nonce_start;
      logic            lc_start;
      logic            lc_stop;
      logic            lc_mat_wr_en;
      logic [5:0]      lc_mat_wr_addr;
      logic [255:0]    lc_mat_wr_data;

      always_ff @(posedge lane_clk[g] or negedge lane_rst_n) begin
        if (!lane_rst_n) begin
          lc_start      <= 1'b0;
          lc_stop       <= 1'b0;
          lc_mat_wr_en  <= 1'b0;
        end else begin
          lc_mid_state_1 <= mid_state_1_r;
          lc_mid_state_2 <= mid_state_2_r;
          lc_msg_block   <= msg_block_r;
          lc_target      <= target_r;
          lc_nonce_start <= nonce_start_r;
          lc_start       <= start_r;
          lc_stop        <= stop_r;
          lc_mat_wr_en   <= mat_wr_en_r;
          lc_mat_wr_addr <= mat_wr_addr_r;
          lc_mat_wr_data <= mat_wr_data_r;
        end
      end

      // ---- Pipeline instance (runs in lane clock domain) ----
      logic       pipe_busy;
      logic       pipe_found;

      heavyhash_pipeline #(
        .NONCE_STEP ( NUM_LANES )
      ) u_pipe (
        .clk         ( lane_clk[g]                ),
        .rst_n       ( lane_rst_n                 ),
        .start       ( lc_start                   ),
        .stop        ( lc_stop                    ),
        .busy        ( pipe_busy                  ),
        .found       ( pipe_found                 ),
        .mid_state_1 ( lc_mid_state_1             ),
        .mid_state_2 ( lc_mid_state_2             ),
        .msg_block   ( lc_msg_block               ),
        .target      ( lc_target                  ),
        .nonce_start ( lc_nonce_start + 64'(g)    ),
        .nonce_found ( lane_nonce_raw[g]          ),
        .hash_count  ( lane_hcount_raw[g]         ),
        .mat_wr_en   ( lc_mat_wr_en               ),
        .mat_wr_addr ( lc_mat_wr_addr             ),
        .mat_wr_data ( lc_mat_wr_data             )
      );

      // ---- CDC: lane clock → base clock (2FF for level signals) ----
      logic [1:0] found_sr;
      logic [1:0] busy_sr;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          found_sr <= 2'b0;
          busy_sr  <= 2'b0;
        end else begin
          found_sr <= {found_sr[0], pipe_found};
          busy_sr  <= {busy_sr[0],  pipe_busy};
        end
      end

      assign lane_found_sync[g] = found_sr[1];
      assign lane_busy_sync[g]  = busy_sr[1];

    end
  endgenerate

  // ================================================================
  //  Output aggregation (base clock domain)
  // ================================================================

  assign busy  = |lane_busy_sync;
  assign found = |lane_found_sync;

  // Priority-encode winning lane (lowest index wins on tie).
  // nonce_found is quasi-static once pipe_found goes high, so
  // reading it from the base domain after found_sync settles is safe.
  always_comb begin
    nonce_found = '0;
    for (int i = NUM_LANES-1; i >= 0; i--) begin
      if (lane_found_sync[i])
        nonce_found = lane_nonce_raw[i];
    end
  end

  // Sum hash counts across all lanes (registered for timing).
  // lane_hcount_raw values are in lane clock domains; reading them
  // from the base clock may see a transient value on rare occasions,
  // but hash_count is only used for status display so this is benign.
  logic [63:0] hcount_sum;

  always_comb begin
    hcount_sum = '0;
    for (int i = 0; i < NUM_LANES; i++)
      hcount_sum = hcount_sum + lane_hcount_raw[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      hash_count <= '0;
    else
      hash_count <= hcount_sum;
  end

endmodule
