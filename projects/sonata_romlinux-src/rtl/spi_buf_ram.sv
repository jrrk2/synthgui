// SPI buffer RAM for the open flow.  Interface as in the original (port A = CPU, port B = SPI core), but built
// only from one-write/one-read arrays: the flow's mapper turns those into block RAM and silently drops a
// true-dual-port array (both ports reading and writing), leaving its read data undriven.
//
//   B_WRITES = 0  (TX buffer)  the CPU writes; the CPU and the SPI core both read.  Two copies of the array,
//                              both written from port A, one read on each port.
//   B_WRITES = 1  (RX buffer)  the SPI core writes; the CPU reads.  The CPU cannot write it.
// Reads are registered and happen when the port's request is high, as before.

module spi_buf_ram #(
  parameter int unsigned Depth = 512,
  parameter bit B_WRITES = 1'b0,
  localparam int unsigned Aw = $clog2(Depth)
) (
  input  logic        clk_i,

  // Port A (CPU)
  input  logic        a_req_i,
  input  logic        a_we_i,
  input  logic [Aw-1:0] a_addr_i,
  input  logic [31:0] a_wdata_i,
  input  logic [3:0]  a_be_i,
  output logic [31:0] a_rdata_o,

  // Port B (SPI core)
  input  logic        b_req_i,
  input  logic        b_we_i,
  input  logic [Aw-1:0] b_addr_i,
  input  logic [31:0] b_wdata_i,
  input  logic [3:0]  b_be_i,
  output logic [31:0] b_rdata_o
);

  if (!B_WRITES) begin : g_tx
    (* ram_style = "block" *) logic [7:0] a0 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] a1 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] a2 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] a3 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] b0 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] b1 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] b2 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] b3 [0:Depth-1];

    wire wr = a_req_i & a_we_i;
    always_ff @(posedge clk_i) begin
      if (wr & a_be_i[0]) a0[a_addr_i] <= a_wdata_i[ 7: 0];
      if (wr & a_be_i[1]) a1[a_addr_i] <= a_wdata_i[15: 8];
      if (wr & a_be_i[2]) a2[a_addr_i] <= a_wdata_i[23:16];
      if (wr & a_be_i[3]) a3[a_addr_i] <= a_wdata_i[31:24];
    end
    always_ff @(posedge clk_i) begin
      if (wr & a_be_i[0]) b0[a_addr_i] <= a_wdata_i[ 7: 0];
      if (wr & a_be_i[1]) b1[a_addr_i] <= a_wdata_i[15: 8];
      if (wr & a_be_i[2]) b2[a_addr_i] <= a_wdata_i[23:16];
      if (wr & a_be_i[3]) b3[a_addr_i] <= a_wdata_i[31:24];
    end
    always_ff @(posedge clk_i) if (a_req_i) a_rdata_o <= {a3[a_addr_i], a2[a_addr_i], a1[a_addr_i], a0[a_addr_i]};
    always_ff @(posedge clk_i) if (b_req_i) b_rdata_o <= {b3[b_addr_i], b2[b_addr_i], b1[b_addr_i], b0[b_addr_i]};
  end else begin : g_rx
    (* ram_style = "block" *) logic [7:0] m0 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] m1 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] m2 [0:Depth-1];
    (* ram_style = "block" *) logic [7:0] m3 [0:Depth-1];

    wire wr = b_req_i & b_we_i;
    always_ff @(posedge clk_i) begin
      if (wr & b_be_i[0]) m0[b_addr_i] <= b_wdata_i[ 7: 0];
      if (wr & b_be_i[1]) m1[b_addr_i] <= b_wdata_i[15: 8];
      if (wr & b_be_i[2]) m2[b_addr_i] <= b_wdata_i[23:16];
      if (wr & b_be_i[3]) m3[b_addr_i] <= b_wdata_i[31:24];
    end
    always_ff @(posedge clk_i) if (a_req_i) a_rdata_o <= {m3[a_addr_i], m2[a_addr_i], m1[a_addr_i], m0[a_addr_i]};
    assign b_rdata_o = 32'b0;
  end

endmodule
