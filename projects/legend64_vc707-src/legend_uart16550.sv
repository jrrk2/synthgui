// SPDX-License-Identifier: Apache-2.0
// legend_uart16550: the subset of a 16550A that Linux's 8250 driver and OpenSBI use.
// Byte-wide registers at offsets 0..7. The line always runs 8N1 at BAUD, derived from the
// system clock by a fractional divider: the divisor latch is stored and read back but has no
// effect. 16-byte receive FIFO; receive-data and transmitter-empty interrupts.
module legend_uart16550 #(
    parameter int unsigned CLK_HZ = 25_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       sel,        // one-cycle access strobe
    input  logic       we,
    input  logic [2:0] addr,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,      // combinational, for the addressed register
    output logic       irq,
    input  logic       rx,
    output logic       tx
);
  // ---------------------------------------------------------------- baud ticks (16x and 1x)
  // phase accumulator: tick16 fires at 16 * BAUD on average
  localparam int unsigned INC = int'((64'd16 * BAUD * 64'd65536) / CLK_HZ);
  logic [16:0] acc;
  logic        tick16;
  always_ff @(posedge clk) begin
    if (rst) acc <= '0;
    else     acc <= {1'b0, acc[15:0]} + 17'(INC);
  end
  assign tick16 = acc[16];

  // ---------------------------------------------------------------- registers
  logic [7:0] ier, lcr, mcr, scr, dll, dlm;
  logic       dlab, thr_full, thre_pending;
  logic [7:0] thr;
  assign dlab = lcr[7];

  // receive FIFO
  logic [7:0] fifo [16];
  logic [4:0] f_cnt;
  logic [3:0] f_rd, f_wr;
  logic       rx_push, overrun;
  logic [7:0] rx_byte;
  logic       rd_rbr, wr_thr;
  assign rd_rbr = sel && !we && addr == 3'd0 && !dlab;
  assign wr_thr = sel && we && addr == 3'd0 && !dlab;

  // ---------------------------------------------------------------- transmitter
  logic [9:0] tx_sr;
  logic [3:0] tx_bits, tx_div;
  logic       tx_busy;
  assign tx_busy = tx_bits != 4'd0;
  assign tx = tx_busy ? tx_sr[0] : 1'b1;
  always_ff @(posedge clk) begin
    if (rst) begin
      tx_bits <= '0; thr_full <= 1'b0; tx_div <= '0; thr <= '0; tx_sr <= '1;
    end else begin
      if (wr_thr) begin thr <= wdata; thr_full <= 1'b1; end
      if (!tx_busy) begin
        if (thr_full && tick16) begin
          tx_sr <= {1'b1, thr, 1'b0}; tx_bits <= 4'd10; tx_div <= 4'd0;
          if (!wr_thr) thr_full <= 1'b0;
        end
      end else if (tick16) begin
        tx_div <= tx_div + 4'd1;
        if (tx_div == 4'd15) begin tx_sr <= {1'b1, tx_sr[9:1]}; tx_bits <= tx_bits - 4'd1; end
      end
    end
  end

  // ---------------------------------------------------------------- receiver
  logic [2:0] rx_sync;
  logic [3:0] rx_div, rx_bits;
  logic       rx_active;
  logic [7:0] rx_sr;
  always_ff @(posedge clk) begin
    rx_sync <= {rx_sync[1:0], rx};
    rx_push <= 1'b0;
    if (rst) begin
      rx_active <= 1'b0;
      rx_sync <= '1; rx_div <= '0; rx_bits <= '0; rx_sr <= '0; rx_byte <= '0;   // the line idles high
    end else if (tick16) begin
      if (!rx_active) begin
        if (!rx_sync[2]) begin rx_active <= 1'b1; rx_div <= 4'd0; rx_bits <= 4'd0; end
      end else begin
        rx_div <= rx_div + 4'd1;
        if (rx_div == 4'd7) begin   // middle of the bit
          if (rx_bits == 4'd0) begin
            if (rx_sync[2]) rx_active <= 1'b0;          // false start
          end else if (rx_bits == 4'd9) begin
            rx_active <= 1'b0;
            if (rx_sync[2]) begin rx_push <= 1'b1; rx_byte <= rx_sr; end
          end else rx_sr <= {rx_sync[2], rx_sr[7:1]};
          rx_bits <= rx_bits + 4'd1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      f_cnt <= '0; f_rd <= '0; f_wr <= '0; overrun <= 1'b0;
      for (int i = 0; i < 16; i++) fifo[i] <= '0;
    end else begin
      if (sel && we && addr == 3'd2 && wdata[1]) begin f_cnt <= '0; f_rd <= '0; f_wr <= '0; end   // FCR: clear receive FIFO
      else begin
        if (rx_push) begin
          if (f_cnt == 5'd16 && !rd_rbr) overrun <= 1'b1;
          else begin fifo[f_wr] <= rx_byte; f_wr <= f_wr + 4'd1; end
        end
        if (rd_rbr && f_cnt != 0) f_rd <= f_rd + 4'd1;
        f_cnt <= f_cnt + 5'((rx_push && !(f_cnt == 5'd16 && !rd_rbr)) ? 1 : 0) - 5'((rd_rbr && f_cnt != 0) ? 1 : 0);
      end
      if (sel && !we && addr == 3'd5) overrun <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- interrupts and register access
  logic irq_rx, irq_thre;
  logic [7:0] lsr, iir;
  assign irq_rx   = ier[0] && f_cnt != 0;
  assign irq_thre = ier[1] && thre_pending;
  assign irq      = irq_rx || irq_thre;
  assign lsr      = {1'b0, !thr_full && !tx_busy, !thr_full, 3'b000, overrun, f_cnt != 0};
  assign iir      = irq_rx ? 8'hc4 : irq_thre ? 8'hc2 : 8'hc1;

  always_comb begin
    unique case (addr)
      3'd0: rdata = dlab ? dll : fifo[f_rd];
      3'd1: rdata = dlab ? dlm : ier;
      3'd2: rdata = iir;
      3'd3: rdata = lcr;
      3'd4: rdata = mcr;
      3'd5: rdata = lsr;
      3'd6: rdata = 8'hb0;   // carrier detect, data set ready, clear to send
      default: rdata = scr;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ier <= '0; lcr <= 8'h03; mcr <= '0; scr <= '0; dll <= 8'h01; dlm <= '0; thre_pending <= 1'b0;
    end else begin
      // The transmitter-empty interrupt is cleared by reading IIR while it is the interrupt
      // being reported, or by writing a byte; it is raised when the holding register drains,
      // and by any write to IER that enables it while the holding register is empty. Raising
      // takes priority over a read of IIR in the same cycle, so an interrupt is never lost.
      if (sel && !we && addr == 3'd2 && iir == 8'hc2) thre_pending <= 1'b0;
      if (thr_full && !tx_busy && tick16 && !wr_thr) thre_pending <= 1'b1;
      if (wr_thr) thre_pending <= 1'b0;
      if (sel && we) begin
        unique case (addr)
          3'd0: if (dlab) dll <= wdata;
          3'd1: if (dlab) dlm <= wdata; else begin
            ier <= wdata & 8'h0f;
            if (wdata[1] && !thr_full) thre_pending <= 1'b1;
          end
          3'd3: lcr <= wdata;
          3'd4: mcr <= wdata;
          3'd7: scr <= wdata;
          default: ;
        endcase
      end
    end
  end
endmodule
