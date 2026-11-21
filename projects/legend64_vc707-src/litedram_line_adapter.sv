// SPDX-License-Identifier: Apache-2.0
// litedram_line_adapter: the cache's line handshake and the SoC's controller-register handshake
// onto a LiteDRAM core's native user port (512-bit data: one cache line per command) and its
// Wishbone control port. Runs on the controller's clock; both requests come from the system
// clock domain as held-steady levels and are synchronised here.
module litedram_line_adapter #(
    parameter int LINE_BITS = 24
) (
    input  logic                 clk,
    input  logic                 rst,

    // cache line port
    input  logic                 req,        // asynchronous, level
    input  logic                 we,
    input  logic [LINE_BITS-1:0] line,
    input  logic [511:0]         wdata,
    output logic                 ack,
    output logic [511:0]         rdata,

    // controller register port
    input  logic                 csr_req,    // asynchronous, level
    input  logic                 csr_we,
    input  logic [13:0]          csr_addr,   // word index
    input  logic [31:0]          csr_wdata,
    output logic                 csr_ack,
    output logic [31:0]          csr_rdata,

    // LiteDRAM native port
    output logic [LINE_BITS-1:0] cmd_addr,
    output logic                 cmd_valid,
    output logic                 cmd_we,
    input  logic                 cmd_ready,
    output logic [511:0]         wdata_data,
    output logic [63:0]          wdata_we,
    output logic                 wdata_valid,
    input  logic                 wdata_ready,
    input  logic [511:0]         rdata_data,
    input  logic                 rdata_valid,
    output logic                 rdata_ready,

    // LiteDRAM Wishbone control port
    output logic [29:0]          wb_adr,
    output logic [31:0]          wb_dat_w,
    output logic [3:0]           wb_sel,
    output logic                 wb_cyc,
    output logic                 wb_stb,
    output logic                 wb_we,
    input  logic                 wb_ack,
    input  logic [31:0]          wb_dat_r
);
  // ------------------------------------------------------------------ line port
  typedef enum logic [1:0] {A_IDLE, A_CMD, A_WAIT, A_ACK} astate_e;
  astate_e state;
  (* ASYNC_REG = "TRUE" *) logic [1:0] req_s;
  logic cmd_done, wd_done, we_q;

  assign cmd_addr    = line;
  assign cmd_we      = we_q;
  assign cmd_valid   = state == A_CMD && !cmd_done;
  assign wdata_valid = state == A_CMD && we_q && !wd_done;
  assign wdata_data  = wdata;
  assign wdata_we    = '1;
  assign rdata_ready = 1'b1;
  assign ack         = state == A_ACK;

  always_ff @(posedge clk) begin
    req_s <= {req_s[0], req};
    if (rst) begin
      state <= A_IDLE;
      req_s <= '0; we_q <= 1'b0; cmd_done <= 1'b0; wd_done <= 1'b0; rdata <= '0;
    end else begin
      unique case (state)
        A_IDLE: if (req_s[1]) begin
          we_q <= we; cmd_done <= 1'b0; wd_done <= 1'b0;
          state <= A_CMD;
        end
        A_CMD: begin
          if (cmd_valid && cmd_ready) cmd_done <= 1'b1;
          if (wdata_valid && wdata_ready) wd_done <= 1'b1;
          if (we_q) begin
            if ((cmd_done || cmd_ready) && (wd_done || wdata_ready)) state <= A_ACK;
          end else if (cmd_done || cmd_ready) state <= A_WAIT;
        end
        A_WAIT: if (rdata_valid) begin
          rdata <= rdata_data;
          state <= A_ACK;
        end
        A_ACK: if (!req_s[1]) state <= A_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------ register port
  (* ASYNC_REG = "TRUE" *) logic [1:0] creq_s;
  logic c_busy;

  assign wb_adr   = {16'b0, csr_addr};
  assign wb_dat_w = csr_wdata;
  assign wb_sel   = 4'hf;
  assign wb_we    = csr_we;
  assign wb_cyc   = c_busy;
  assign wb_stb   = c_busy;

  always_ff @(posedge clk) begin
    creq_s <= {creq_s[0], csr_req};
    if (rst) begin
      c_busy <= 1'b0; csr_ack <= 1'b0; creq_s <= '0; csr_rdata <= '0;
    end else if (c_busy) begin
      if (wb_ack) begin c_busy <= 1'b0; csr_ack <= 1'b1; csr_rdata <= wb_dat_r; end
    end else if (csr_ack) begin
      if (!creq_s[1]) csr_ack <= 1'b0;
    end else if (creq_s[1]) c_busy <= 1'b1;
  end
endmodule
