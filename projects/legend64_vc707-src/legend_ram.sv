// SPDX-License-Identifier: Apache-2.0
// Inferred block RAMs used by the VC707 system.

// Two read ports, byte-enabled write on port B, one clock. Port B reads the old contents
// during a write.
module legend_tdp_be #(
    parameter int AW = 10,
    parameter int NB = 4,            // width in bytes
    parameter     INIT_FILE = ""
) (
    input  logic            clk,
    input  logic [AW-1:0]   a_addr,
    output logic [8*NB-1:0] a_q,
    input  logic [AW-1:0]   b_addr,
    input  logic [NB-1:0]   b_we,
    input  logic [8*NB-1:0] b_d,
    output logic [8*NB-1:0] b_q
);
  (* ram_style = "block" *) logic [8*NB-1:0] mem[1 << AW];
  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    else for (int i = 0; i < (1 << AW); i++) mem[i] = '0;
  end
  always_ff @(posedge clk) a_q <= mem[a_addr];
  always_ff @(posedge clk) begin
    for (int b = 0; b < NB; b++) if (b_we[b]) mem[b_addr][8*b+:8] <= b_d[8*b+:8];
    b_q <= mem[b_addr];
  end
endmodule

// True dual-clock RAM, 32 bits wide: port A byte-enabled read/write, port B word read/write.
module legend_dc_ram32 #(
    parameter int AW = 10
) (
    input  logic          a_clk,
    input  logic          a_en,
    input  logic [3:0]    a_we,
    input  logic [AW-1:0] a_addr,
    input  logic [31:0]   a_d,
    output logic [31:0]   a_q,
    input  logic          b_clk,
    input  logic          b_en,
    input  logic          b_we,
    input  logic [AW-1:0] b_addr,
    input  logic [31:0]   b_d,
    output logic [31:0]   b_q
);
  (* ram_style = "block" *) logic [31:0] mem[1 << AW];
  always_ff @(posedge a_clk) if (a_en) begin
    for (int b = 0; b < 4; b++) if (a_we[b]) mem[a_addr][8*b+:8] <= a_d[8*b+:8];
    a_q <= mem[a_addr];
  end
  always_ff @(posedge b_clk) if (b_en) begin
    if (b_we) mem[b_addr] <= b_d;
    b_q <= mem[b_addr];
  end
endmodule
