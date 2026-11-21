// SPDX-License-Identifier: Apache-2.0
// legend_cache: one direct-mapped cache in front of the DDR3 memory, shared by the instruction
// and data ports of legend64 so that code written through the data port is what gets fetched.
//
// Lines are 64 bytes, which is exactly one burst of the memory controller (512 bits), so a
// miss is one read and an eviction of a modified line is one write. Each core port has its
// own port on the block RAMs; a hit answers in the cycle after the request, which is the
// timing legend64's bus expects. A store takes one extra cycle. While a miss is handled both
// ports wait.
//
// A third, "device" port lets a DMA master (the Ethernet MAC) read and write memory through
// the same cache, so what the device and the CPU see is always coherent and packet data the
// device has just written is already in the cache when the CPU reads it. It shares the data
// port's block-RAM port; when both ask in the same cycle they alternate.
//
// Memory side: a four-phase request/acknowledge handshake carrying a whole line. mem_addr,
// mem_we and mem_wdata are held steady while mem_req is high, and mem_rdata is steady while
// mem_ack is high, so the other side may sit in a different clock domain.
module legend_cache #(
    parameter int LINES_LOG2 = 10,   // 1024 lines = 64 KiB
    parameter int ADDR_BITS  = 30    // 1 GiB
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        i_req,
    input  logic [ADDR_BITS-1:0] i_addr,
    output logic        i_gnt,
    output logic        i_rvalid,
    output logic [31:0] i_rdata,

    input  logic        d_req,
    input  logic        d_we,
    input  logic [ADDR_BITS-1:0] d_addr,
    input  logic [63:0] d_wdata,
    input  logic [7:0]  d_be,
    output logic        d_gnt,
    output logic        d_rvalid,
    output logic [63:0] d_rdata,

    input  logic        e_req,
    input  logic        e_we,
    input  logic [ADDR_BITS-1:0] e_addr,
    input  logic [63:0] e_wdata,
    input  logic [7:0]  e_be,
    output logic        e_gnt,
    output logic        e_rvalid,
    output logic [63:0] e_rdata,

    output logic        mem_req,
    output logic        mem_we,
    output logic [ADDR_BITS-7:0] mem_addr,   // line number
    output logic [511:0] mem_wdata,
    input  logic        mem_ack,             // asynchronous
    input  logic [511:0] mem_rdata
);
  localparam int IW = LINES_LOG2;
  localparam int TW = ADDR_BITS - 6 - IW;

  typedef enum logic [3:0] {S_RUN, S_VREAD, S_VLATCH, S_WB, S_WB_DONE, S_RD, S_FILL, S_RD_DONE, S_REPLAY} state_e;
  state_e state;

  logic                 i_pend, d_pend, d_pwe, d_psrc, prefer_e, slot_free, take_e;
  logic [ADDR_BITS-1:0] s_addr;
  logic [ADDR_BITS-1:0] i_pa, d_pa, fill_addr;
  logic [63:0]          d_pwd;
  logic [7:0]           d_pbe;

  logic [IW-1:0]  a_idx, b_idx;
  logic [63:0]    b_we;
  logic [511:0]   a_line, b_line, b_wline, v_line;
  logic [1:0]     t_we;
  logic [15:0]    a_tag, b_tag, t_wd, v_tag;   // {valid, modified, tag}

  legend_tdp_be #(.AW(IW), .NB(64)) u_data (
      .clk, .a_addr(a_idx), .a_q(a_line), .b_addr(b_idx), .b_we(b_we), .b_d(b_wline), .b_q(b_line));
  legend_tdp_be #(.AW(IW), .NB(2)) u_tag (
      .clk, .a_addr(a_idx), .a_q(a_tag), .b_addr(b_idx), .b_we(t_we), .b_d(t_wd), .b_q(b_tag));

  function automatic logic [IW-1:0] idx(input logic [ADDR_BITS-1:0] a); return a[6+:IW]; endfunction
  function automatic logic [TW-1:0] tag(input logic [ADDR_BITS-1:0] a); return a[ADDR_BITS-1:6+IW]; endfunction

  logic i_hit, d_hit, i_miss, d_miss, d_wr_hit;
  assign i_hit    = i_pend && a_tag[15] && a_tag[TW-1:0] == tag(i_pa);
  assign d_hit    = d_pend && b_tag[15] && b_tag[TW-1:0] == tag(d_pa);
  assign i_miss   = i_pend && !i_hit;
  assign d_miss   = d_pend && !d_hit;
  assign d_wr_hit = state == S_RUN && d_hit && d_pwe;

  assign i_gnt    = state == S_RUN && (!i_pend || i_hit);
  // the data-side slot is shared by the core's data port and the device port
  assign slot_free = state == S_RUN && (!d_pend || (d_hit && !d_pwe));
  assign take_e    = e_req && (!d_req || prefer_e);
  assign d_gnt     = slot_free && !take_e;
  assign e_gnt     = slot_free && take_e;
  assign s_addr    = take_e ? e_addr : d_addr;
  assign i_rvalid  = state == S_RUN && i_hit;
  assign d_rvalid  = state == S_RUN && d_hit && !d_pwe && !d_psrc;
  assign e_rvalid  = state == S_RUN && d_hit && !d_pwe && d_psrc;
  assign e_rdata   = d_rdata;
  assign i_rdata  = a_line[{i_pa[5:2], 5'b0}+:32];
  assign d_rdata  = b_line[{d_pa[5:3], 6'b0}+:64];

  // memory handshake
  logic ack_s1, ack_s2;
  always_ff @(posedge clk) begin
    if (rst) begin
      ack_s1 <= 1'b0; ack_s2 <= 1'b0;
    end else begin
      ack_s1 <= mem_ack;
      ack_s2 <= ack_s1;
    end
  end
  assign mem_req   = state == S_WB || state == S_RD;
  assign mem_we    = state == S_WB || state == S_WB_DONE;
  assign mem_addr  = mem_we ? {v_tag[TW-1:0], idx(fill_addr)} : fill_addr[ADDR_BITS-1:6];
  assign mem_wdata = v_line;

  // block RAM port control
  always_comb begin
    a_idx   = i_addr[6+:IW];
    b_idx   = s_addr[6+:IW];
    b_we    = '0;
    b_wline = {8{d_pwd}};
    t_we    = '0;
    t_wd    = {2'b11, 14'(tag(d_pa))};
    unique case (state)
      S_RUN: begin
        if (!i_gnt) a_idx = idx(i_pa);
        if (d_wr_hit) begin
          b_idx = idx(d_pa);
          b_we  = 64'(d_pbe) << {d_pa[5:3], 3'b0};
          t_we  = 2'b11;
        end else if (!slot_free) b_idx = idx(d_pa);
      end
      S_FILL: begin
        b_idx   = idx(fill_addr);
        b_we    = '1;
        b_wline = mem_rdata;
        t_we    = 2'b11;
        t_wd    = {2'b10, 14'(tag(fill_addr))};
      end
      S_REPLAY: begin
        a_idx = idx(i_pa);
        b_idx = idx(d_pa);
      end
      default: begin
        a_idx = idx(i_pa);
        b_idx = idx(fill_addr);
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state  <= S_RUN;
      i_pend <= 1'b0;
      d_pend <= 1'b0;
      prefer_e <= 1'b0;
      // the pending requests' details and the line being replaced: loaded before they are used
      i_pa <= '0; d_pa <= '0; d_psrc <= 1'b0; d_pwe <= 1'b0; d_pwd <= '0; d_pbe <= '0;
      fill_addr <= '0; v_line <= '0; v_tag <= '0;
    end else begin
      unique case (state)
        S_RUN: begin
          if (i_hit) i_pend <= 1'b0;
          if (d_hit) d_pend <= 1'b0;
          if (i_req && i_gnt) begin i_pend <= 1'b1; i_pa <= i_addr; end
          if (slot_free && (d_req || e_req)) begin
            d_pend <= 1'b1; d_psrc <= take_e; d_pa <= s_addr;
            d_pwe <= take_e ? e_we : d_we; d_pwd <= take_e ? e_wdata : d_wdata; d_pbe <= take_e ? e_be : d_be;
            if (d_req && e_req) prefer_e <= !take_e;
          end
          if (d_miss)      begin fill_addr <= d_pa; state <= S_VREAD; end
          else if (i_miss) begin fill_addr <= i_pa; state <= S_VREAD; end
        end
        // read the line about to be replaced through the write port, after any store has landed
        S_VREAD:  state <= S_VLATCH;
        S_VLATCH: begin
          v_line <= b_line;
          v_tag  <= b_tag;
          state  <= (b_tag[15] && b_tag[14]) ? S_WB : S_RD;
        end
        S_WB:      if (ack_s2)  state <= S_WB_DONE;
        S_WB_DONE: if (!ack_s2) state <= S_RD;
        S_RD:      if (ack_s2)  state <= S_FILL;
        S_FILL:    state <= S_RD_DONE;
        S_RD_DONE: if (!ack_s2) state <= S_REPLAY;
        S_REPLAY:  state <= S_RUN;
        default:   state <= S_RUN;
      endcase
    end
  end
endmodule
