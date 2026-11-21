// SPDX-License-Identifier: Apache-2.0
// legend_flash: a memory-mapped window onto a parallel NOR flash with an asynchronous bus (the
// VC707's linear BPI flash, 16 bits wide). It runs bus cycles and nothing more: the command
// sequences that identify, erase and program the device are software's (the kernel's CFI
// driver, or the monitor).
//
// The core holds a request steady until `gnt`. A 64-bit bus word covers four flash words:
//   read   the flash words from the addressed one to the end of the bus word are read in
//          turn, since a load does not say how wide it is; reading flash has no side effects
//   write  the flash words that have a byte enable set are written, lowest first
// Bytes are little-endian: flash data bit 0 is bit 0 of the byte at the even address.
//
// Timing is counted in system clock cycles from the two figures below, which leave margin
// over the device's 96 ns access time and 50 ns write pulse for the pads and the board.
module legend_flash #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned AW     = 24,     // flash word address lines driven
    parameter int unsigned ACC_NS = 150,    // address, CE and OE valid to data sampled
    parameter int unsigned WP_NS  = 70      // write pulse; also data set-up
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          req,              // held until gnt
    input  logic          we,
    input  logic [AW:1]   addr,             // byte address bits AW..1
    input  logic [7:0]    be,               // writes only
    input  logic [63:0]   wdata,
    output logic          gnt,              // one cycle; rdata is valid from the next cycle
    output logic [63:0]   rdata,

    output logic [AW-1:0] fl_addr,
    input  logic [15:0]   fl_dq_i,
    output logic [15:0]   fl_dq_o,
    output logic          fl_dq_t,          // 1: the data pins are inputs
    output logic          fl_ce_n,
    output logic          fl_oe_n,
    output logic          fl_we_n,
    output logic          fl_adv_n
);
  function automatic int unsigned cycles(input int unsigned ns);
    return int'((longint'(ns) * CLK_HZ + 999_999_999) / 1_000_000_000);
  endfunction
  localparam int unsigned T_ACC = cycles(ACC_NS) < 2 ? 2 : cycles(ACC_NS);
  localparam int unsigned T_WP  = cycles(WP_NS) < 1 ? 1 : cycles(WP_NS);
  localparam int unsigned TW    = $clog2(T_ACC + 1);

  typedef enum logic [2:0] {S_IDLE, S_READ, S_SETUP, S_PULSE, S_HOLD, S_NEXT, S_DONE} state_t;
  state_t          state;
  logic [1:0]      lane;
  logic [3:0]      todo;       // lanes still to write
  logic [TW-1:0]   cnt;
  logic [3:0]      wr_lanes;

  assign wr_lanes = {|be[7:6], |be[5:4], |be[3:2], |be[1:0]};
  assign fl_adv_n = 1'b0;      // address latch transparent
  assign gnt      = state == S_DONE;

  // lowest lane set in a non-zero mask
  function automatic logic [1:0] first(input logic [3:0] m);
    return m[0] ? 2'd0 : m[1] ? 2'd1 : m[2] ? 2'd2 : 2'd3;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE; lane <= '0; todo <= '0; cnt <= '0; rdata <= '0;
      fl_addr <= '0; fl_dq_o <= '0; fl_dq_t <= 1'b1; fl_ce_n <= 1'b1; fl_oe_n <= 1'b1; fl_we_n <= 1'b1;
    end else begin
      case (state)
        S_IDLE: if (req) begin
          fl_ce_n <= 1'b0;
          if (!we) begin
            lane <= addr[2:1]; fl_addr <= addr[AW:1];
            fl_oe_n <= 1'b0; cnt <= TW'(T_ACC); state <= S_READ;
          end else if (wr_lanes != '0) begin
            lane <= first(wr_lanes); todo <= wr_lanes & ~(4'b1 << first(wr_lanes));
            fl_addr <= {addr[AW:3], first(wr_lanes)};
            fl_dq_o <= wdata[16*first(wr_lanes)+:16]; fl_dq_t <= 1'b0;
            cnt <= TW'(T_WP); state <= S_SETUP;
          end else begin
            fl_ce_n <= 1'b1; state <= S_DONE;
          end
        end
        S_READ: begin
          cnt <= cnt - 1'b1;
          if (cnt == '0) begin
            rdata[16*lane+:16] <= fl_dq_i;
            if (lane == 2'd3) begin fl_oe_n <= 1'b1; fl_ce_n <= 1'b1; state <= S_DONE; end
            else begin lane <= lane + 1'b1; fl_addr[1:0] <= lane + 1'b1; cnt <= TW'(T_ACC); end
          end
        end
        S_SETUP: begin fl_we_n <= 1'b0; state <= S_PULSE; end
        S_PULSE: begin
          cnt <= cnt - 1'b1;
          if (cnt == '0) begin fl_we_n <= 1'b1; state <= S_HOLD; end
        end
        S_HOLD: begin fl_dq_t <= 1'b1; state <= S_NEXT; end      // data held one cycle past WE
        S_NEXT: begin                                           // WE high for two cycles
          if (todo != '0) begin
            lane <= first(todo); todo <= todo & ~(4'b1 << first(todo));
            fl_addr[1:0] <= first(todo);
            fl_dq_o <= wdata[16*first(todo)+:16]; fl_dq_t <= 1'b0;
            cnt <= TW'(T_WP); state <= S_SETUP;
          end else begin fl_ce_n <= 1'b1; state <= S_DONE; end
        end
        S_DONE: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
