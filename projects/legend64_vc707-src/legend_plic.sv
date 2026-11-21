// SPDX-License-Identifier: Apache-2.0
// legend_plic: platform-level interrupt controller with the standard (SiFive) register layout,
// for one hart with a machine context (0) and a supervisor context (1).
//   0x000000 + 4*n  priority of source n            0x001000  pending bits
//   0x002000        enables, context 0              0x002080  enables, context 1
//   0x200000        threshold, context 0            0x200004  claim/complete, context 0
//   0x201000        threshold, context 1            0x201004  claim/complete, context 1
// Sources are level-sensitive. Source 0 does not exist.
module legend_plic #(
    parameter int NSRC = 31,     // sources 1..NSRC
    parameter int PRIO_BITS = 3
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        sel,       // one-cycle access strobe
    input  logic        we,
    input  logic [25:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,     // registered: valid the cycle after sel
    input  logic [NSRC:1] src,
    output logic        irq_m,
    output logic        irq_s
);
  logic [PRIO_BITS-1:0] prio [NSRC+1];
  logic [NSRC:0]        pending, in_service, enable [2];
  logic [PRIO_BITS-1:0] threshold [2];
  logic [5:0]           best [2];
  logic [PRIO_BITS-1:0] best_prio [2];

  // The highest-priority pending and enabled source of each context, the lowest numbered among
  // equals; none (0) if every candidate has priority 0. A balanced tree of pairwise choices: a
  // chain through the sources one after another was 80 logic levels deep.
  localparam int LEAVES = 1 << $clog2(NSRC + 1);
  logic [PRIO_BITS-1:0] tree_p [2][2*LEAVES];
  logic [5:0]           tree_i [2][2*LEAVES];
  always_comb begin
    for (int c = 0; c < 2; c++) begin
      tree_p[c][0] = '0; tree_i[c][0] = '0;
      for (int i = 0; i < LEAVES; i++) begin
        tree_p[c][LEAVES + i] = (i >= 1 && i <= NSRC && pending[i > NSRC ? 0 : i] && enable[c][i > NSRC ? 0 : i]) ? prio[i > NSRC ? 0 : i] : '0;
        tree_i[c][LEAVES + i] = 6'(i);
      end
      for (int n = LEAVES - 1; n >= 1; n--) begin
        if (tree_p[c][2*n] >= tree_p[c][2*n + 1]) begin tree_p[c][n] = tree_p[c][2*n];     tree_i[c][n] = tree_i[c][2*n]; end
        else                                      begin tree_p[c][n] = tree_p[c][2*n + 1]; tree_i[c][n] = tree_i[c][2*n + 1]; end
      end
      best_prio[c] = tree_p[c][1];
      best[c]      = tree_p[c][1] == '0 ? 6'd0 : tree_i[c][1];
    end
  end

  logic claim_m, claim_s;
  assign claim_m = sel && !we && addr == 26'h200004;
  assign claim_s = sel && !we && addr == 26'h201004;

  always_ff @(posedge clk) begin
    irq_m <= best_prio[0] > threshold[0];
    irq_s <= best_prio[1] > threshold[1];
    if (rst) begin
      pending <= '0; in_service <= '0; enable[0] <= '0; enable[1] <= '0;
      threshold[0] <= '0; threshold[1] <= '0;
      for (int i = 0; i <= NSRC; i++) prio[i] <= '0;
      irq_m <= 1'b0; irq_s <= 1'b0; rdata <= '0;
    end else begin
      // gateway: a source becomes pending while its line is high and it is not being serviced
      for (int i = 1; i <= NSRC; i++) if (src[i] && !in_service[i]) pending[i] <= 1'b1;
      if (claim_m && best[0] != 0) begin pending[best[0]] <= 1'b0; in_service[best[0]] <= 1'b1; end
      if (claim_s && best[1] != 0) begin pending[best[1]] <= 1'b0; in_service[best[1]] <= 1'b1; end
      if (sel && !we) begin
        rdata <= '0;
        if (addr < 26'h80)              rdata <= 32'(prio[addr[6:2]]);
        else if (addr == 26'h1000)      rdata <= 32'(pending);
        else if (addr == 26'h2000)      rdata <= 32'(enable[0]);
        else if (addr == 26'h2080)      rdata <= 32'(enable[1]);
        else if (addr == 26'h200000)    rdata <= 32'(threshold[0]);
        else if (addr == 26'h201000)    rdata <= 32'(threshold[1]);
        else if (addr == 26'h200004)    rdata <= 32'(best[0]);
        else if (addr == 26'h201004)    rdata <= 32'(best[1]);
      end
      if (sel && we) begin
        if (addr < 26'h80 && addr[6:2] != 0) prio[addr[6:2]] <= wdata[PRIO_BITS-1:0];
        else if (addr == 26'h2000)   enable[0] <= {wdata[NSRC:1], 1'b0};
        else if (addr == 26'h2080)   enable[1] <= {wdata[NSRC:1], 1'b0};
        else if (addr == 26'h200000) threshold[0] <= wdata[PRIO_BITS-1:0];
        else if (addr == 26'h201000) threshold[1] <= wdata[PRIO_BITS-1:0];
        else if ((addr == 26'h200004 || addr == 26'h201004) && wdata[5:0] != 0 && wdata[5:0] <= 6'(NSRC))
          in_service[wdata[5:0]] <= 1'b0;   // completion
      end
    end
  end
endmodule
