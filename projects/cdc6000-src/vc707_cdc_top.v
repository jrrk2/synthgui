// VC707 top level for the CDC 6000 core (rtl/cdc6000_core.sv) running the 1972 Pascal compiler.
//
// The memory is initialised from mem.hex (runtime + program, see mkmem.py).  The core's five I/O words become a
// byte stream on the USB UART (CP2103), 8N1 at BAUD:
//   host -> board   a byte 0..63 is an input character in display code (line end = 0); 0x80 = end of input.
//                   The board has a 2048 byte input FIFO and returns a credit byte 0x83 for every 256 characters the
//                   program has consumed, so the host sends 1024 bytes ahead and one block per credit.
//   board -> host   0x00..0x3F  an output character (display code)
//                   0x81 + 8 bytes name + 8 bytes word    a word of the binary file called name (LFN, big endian)
//                   0x82 + icount(8) + cycles(8) + fault(1)   the core halted
//                   0x83  credit    0x85  the board is up and the program is waiting for input
// LEDs: 0 heartbeat, 1 MMCM locked, 2 running, 3 halted, 4 fault, 5 input FIFO overflow, 6 output pending, 7 CPU_RESET.
// CPU_RESET restarts the core but not the memory (the program has modified it): reprogram the FPGA to run again.

module vc707_cdc_top #(
    parameter CLK_MHZ = 25,
    parameter BAUD    = 921600
) (
    input        clk200_p,
    input        clk200_n,
    input        cpu_reset,
    input        serial_rx,
    output       serial_tx,
    output [7:0] leds
);
  localparam CLK_HZ = CLK_MHZ * 1000000;

  // ---------------------------------------------------------------- clocking
  wire clk200, mmcm_fb, clk_mmcm, locked, clk;
  IBUFDS clk200_buf (.I(clk200_p), .IB(clk200_n), .O(clk200));
  MMCME2_ADV #(
      .BANDWIDTH       ("OPTIMIZED"),
      .CLKFBOUT_MULT_F (5),
      .CLKIN1_PERIOD   (5.0),
      .CLKOUT0_DIVIDE_F(1000.0 / CLK_MHZ),
      .CLKOUT0_PHASE   (0),
      .DIVCLK_DIVIDE   (1),
      .REF_JITTER1     (0.01)
  ) mmcm (
      .CLKFBIN (mmcm_fb),
      .CLKIN1  (clk200),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKFBOUT(mmcm_fb),
      .CLKOUT0 (clk_mmcm),
      .LOCKED  (locked)
  );
  BUFG clk_buf (.I(clk_mmcm), .O(clk));

  // reset held until the MMCM has been locked for 2^16 cycles
  reg [1:0] locked_sync = 2'b00;
  reg [16:0] por = 17'd0;
  wire rst = !por[16];
  always @(posedge clk) begin
    locked_sync <= {locked_sync[0], locked};
    if (!locked_sync[1]) por <= 17'd0;
    else if (rst) por <= por + 17'd1;
  end
  reg [1:0] btn_sync = 2'b00;
  always @(posedge clk) btn_sync <= {btn_sync[0], cpu_reset};
  wire core_rst = rst | btn_sync[1];

  // ---------------------------------------------------------------- the core
  wire        rx_valid, rx_eof, rx_take, tx_valid, tx_ready, fo_valid, fo_ready, halted, fault;
  wire [5:0]  rx_char, tx_char;
  wire [59:0] fo_name, fo_word;
  wire [17:0] dbg_pc;
  wire [63:0] icount;

  cdc6000_core #(.MEM_AW(17), .MEM_INIT("mem.hex")) core (
      .clk(clk), .reset(core_rst),
      .ext_addr(), .ext_we(), .ext_wdata(), .ext_rdata(60'd0),
      .load_we(1'b0), .load_addr(17'd0), .load_data(60'd0),
      .rx_valid(rx_valid), .rx_char(rx_char), .rx_eof(rx_eof), .rx_take(rx_take),
      .tx_valid(tx_valid), .tx_char(tx_char), .tx_ready(tx_ready),
      .fo_valid(fo_valid), .fo_name(fo_name), .fo_word(fo_word), .fo_ready(fo_ready),
      .dev_req(), .dev_we(), .dev_off(), .dev_wdata(), .dev_ack(1'b0), .dev_rdata(60'd0),
      .halted(halted), .fault(fault), .dbg_pc(dbg_pc), .icount(icount)
  );

  // ---------------------------------------------------------------- UART
  reg [2:0] rxs = 3'b111;
  always @(posedge clk) rxs <= {rxs[1:0], serial_rx};

  wire        uart_wait;
  wire [31:0] uart_do;
  reg  [7:0]  txq;           // byte being sent
  reg         txq_valid;
  wire        rx_have = !uart_do[31];
  reg         rx_ack;
  wire        rx_fire = rx_have && !rx_ack;

  simpleuart #(.DEFAULT_DIV(CLK_HZ / BAUD - 1)) uart (
      .clk(clk), .resetn(!rst),
      .ser_tx(serial_tx), .ser_rx(rxs[2]),
      .reg_div_we(4'b0000), .reg_div_di(32'd0), .reg_div_do(),
      .reg_dat_we(txq_valid), .reg_dat_re(rx_fire),
      .reg_dat_di({24'd0, txq}), .reg_dat_do(uart_do), .reg_dat_wait(uart_wait)
  );
  always @(posedge clk) rx_ack <= rx_fire;

  wire credit_start;

  // ---------------------------------------------------------------- input FIFO (2048 x 8) and the core's view of it
  reg [7:0]  rxf [0:2047];
  reg [11:0] rx_wp = 12'd0, rx_rp = 12'd0;
  reg [7:0]  rx_rdata;
  wire       rx_empty = (rx_wp == rx_rp);
  wire       rx_full  = (rx_wp[10:0] == rx_rp[10:0]) && (rx_wp[11] != rx_rp[11]);
  reg        rx_overflow = 1'b0;
  always @(posedge clk) begin
    if (rx_fire && !rx_full) rxf[rx_wp[10:0]] <= uart_do[7:0];
    rx_rdata <= rxf[rx_rp[10:0]];
  end
  reg       hv = 1'b0, rd_pend = 1'b0;
  reg [7:0] hd;
  reg [7:0] consumed = 8'd0;
  reg       credit_req = 1'b0;
  always @(posedge clk) begin
    if (rst) begin
      rx_wp <= 12'd0; rx_rp <= 12'd0; hv <= 1'b0; rd_pend <= 1'b0; consumed <= 8'd0; credit_req <= 1'b0;
      rx_overflow <= 1'b0;
    end else begin
      if (rx_fire) begin
        if (rx_full) rx_overflow <= 1'b1; else rx_wp <= rx_wp + 12'd1;
      end
      if (rx_take) begin
        hv <= 1'b0;
        consumed <= consumed + 8'd1;
        if (consumed == 8'd255) credit_req <= 1'b1;
      end else if (!hv && !rd_pend && !rx_empty) rd_pend <= 1'b1;
      if (rd_pend) begin hd <= rx_rdata; hv <= 1'b1; rx_rp <= rx_rp + 12'd1; rd_pend <= 1'b0; end
      if (credit_start) credit_req <= 1'b0;
    end
  end
  assign rx_valid = hv;
  assign rx_eof   = (hd == 8'h80);
  assign rx_char  = hd[5:0];

  // ---------------------------------------------------------------- output: serializer and FIFO (2048 x 8)
  reg [143:0] sbuf;
  reg [4:0]   scnt = 5'd0;
  reg         ready_sent = 1'b0, report_sent = 1'b0;
  reg [63:0]  cycles = 64'd0;
  wire        idle = (scnt == 5'd0);
  assign      credit_start = idle && !fo_valid && credit_req && !tx_valid;
  wire        ready_start  = idle && !fo_valid && !credit_req && !ready_sent && !rst;
  wire        report_start = idle && !fo_valid && !credit_req && ready_sent && halted && !report_sent;

  reg [7:0]  txf [0:2047];
  reg [11:0] tx_wp = 12'd0, tx_rp = 12'd0;
  wire [11:0] tx_used = tx_wp - tx_rp;
  wire        tx_full = (tx_used >= 12'd2040);
  wire        tx_empty = (tx_wp == tx_rp);
  reg         push;
  reg [7:0]   pushd;

  assign tx_ready = idle && !fo_valid && !tx_full && ready_sent;
  assign fo_ready = idle && !fo_valid && !credit_req && ready_sent;

  always @(*) begin
    push = 1'b0; pushd = 8'd0;
    if (tx_valid) begin push = 1'b1; pushd = {2'b00, tx_char}; end
    else if (!idle && !tx_full) begin push = 1'b1; pushd = sbuf[143:136]; end
  end

  always @(posedge clk) begin
    if (rst) begin
      scnt <= 5'd0; ready_sent <= 1'b0; report_sent <= 1'b0; cycles <= 64'd0; tx_wp <= 12'd0;
    end else begin
      if (!halted) cycles <= cycles + 64'd1;
      if (push) begin txf[tx_wp[10:0]] <= pushd; tx_wp <= tx_wp + 12'd1; end
      if (fo_valid) begin
        sbuf <= {8'h81, 4'd0, fo_name, 4'd0, fo_word, 8'd0}; scnt <= 5'd17;
      end else if (credit_start) begin
        sbuf <= {8'h83, 136'd0}; scnt <= 5'd1;
      end else if (ready_start) begin
        sbuf <= {8'h85, 136'd0}; scnt <= 5'd1; ready_sent <= 1'b1;
      end else if (report_start) begin
        sbuf <= {8'h82, icount, cycles, 7'd0, fault}; scnt <= 5'd18; report_sent <= 1'b1;
      end else if (!idle && !tx_valid && !tx_full) begin
        sbuf <= {sbuf[135:0], 8'd0}; scnt <= scnt - 5'd1;
      end
    end
  end

  // FIFO -> UART
  reg        txq_pend;
  reg [7:0]  tx_rdata;
  always @(posedge clk) tx_rdata <= txf[tx_rp[10:0]];
  wire txq_takes = txq_valid && !uart_wait;
  always @(posedge clk) begin
    if (rst) begin
      tx_rp <= 12'd0; txq_valid <= 1'b0; txq_pend <= 1'b0;
    end else begin
      if (!txq_valid && !txq_pend && !tx_empty) txq_pend <= 1'b1;
      if (txq_pend) begin txq <= tx_rdata; txq_valid <= 1'b1; tx_rp <= tx_rp + 12'd1; txq_pend <= 1'b0; end
      else if (txq_takes) txq_valid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- LEDs
  reg [24:0] heartbeat = 25'd0;
  always @(posedge clk) heartbeat <= heartbeat + 25'd1;
  assign leds = {btn_sync[1], !tx_empty || txq_valid, rx_overflow, fault, halted, !halted && !rst, locked, heartbeat[24]};
endmodule
