// Minimal-UART variant of the DSP calculator for the OPEN FLOW: drops the big
// apb_uart + APB master (which owned ~half the cells and 2 of the 5 stuck
// routing arcs) and uses the proven carry-free LFSR UART (lfsr_div baud +
// uart_rx_lfsr RX + uart_transmitter TX, HW-verified in uartadd4's open flow).
// 200 MHz sysclk through an MMCM to a 100 MHz core clock; 115200 8N1 (LFSR divide-by-54 =
// 16x baud, divide-by-8 = 2x).
module top (
`ifdef USE_USERCLK
    input  wire       user_clock_p,
    input  wire       user_clock_n,
`else
    input  wire       sysclk_p,
    input  wire       sysclk_n,
`endif
    input  wire       rst,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led
);
    wire clk_raw, clk, rst_buf, rx_buf, locked;
    IBUFDS #(.DIFF_TERM("TRUE"),.IBUF_LOW_PWR("FALSE"),.IOSTANDARD("LVDS"))
`ifdef USE_USERCLK
        ibufds (.I(user_clock_p), .IB(user_clock_n), .O(clk_raw));   // 156.25 MHz Si570
    BUFG bufg (.I(clk_raw), .O(clk));
    assign locked = 1'b1;
`else
        ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_raw));           // 200 MHz Si5324
    // 200 MHz x5 = 1 GHz VCO, /10 = 100 MHz: the design's block RAM read paths, which
    // nextpnr now times, do not close 200 MHz.  Direct feedback, as vc707_bramtest's
    // clkgen_vc707 (proven on the board in this flow).
    wire clk_mmcm, clk_fb;
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(5.000), .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(10.000), .CLKOUT0_PHASE(0.000), .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKIN1_PERIOD(5.000)
    ) mmcm (
        .CLKFBOUT(clk_fb), .CLKFBOUTB(), .CLKOUT0(clk_mmcm), .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBIN(clk_fb), .CLKIN1(clk_raw), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .DADDR(7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0), .DO(), .DRDY(), .DWE(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
        .CLKINSTOPPED(), .CLKFBSTOPPED(), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG bufg (.I(clk_mmcm), .O(clk));
`endif
    IBUF ibuf_rst (.I(rst), .O(rst_buf));
    IBUF ibuf_rx  (.I(rx),  .O(rx_buf));

    // All behavioral logic lives in calc_inner so `top` is a PURE structural
    // wrapper (primitives + one child).  This matches the SVS-native flow's
    // supported shape: gate-map the single behavioral child (clk/rst/rx as
    // ports), keep the primitives in the wrapper, splice + flatten_struct.
    wire sout; wire [7:0] led_int;
    calc_inner inner (.clk(clk), .locked(locked), .rst_buf(rst_buf), .rx_buf(rx_buf),
                      .tx_bit(sout), .led(led_int));

    OBUF obuf_tx (.I(sout), .O(tx));
    OBUF o0(.I(led_int[0]),.O(led[0])); OBUF o1(.I(led_int[1]),.O(led[1]));
    OBUF o2(.I(led_int[2]),.O(led[2])); OBUF o3(.I(led_int[3]),.O(led[3]));
    OBUF o4(.I(led_int[4]),.O(led[4])); OBUF o5(.I(led_int[5]),.O(led[5]));
    OBUF o6(.I(led_int[6]),.O(led[6])); OBUF o7(.I(led_int[7]),.O(led[7]));
endmodule

// calc_inner: ALL the behavioral logic — CPU + DSP48E1 + BRAM (calc_core),
// LFSR baud dividers, RX/TX byte FIFOs, UART RX/TX, POR.  clk/rst_buf/rx_buf
// arrive as ports (so the gate-mapper binds them); `top` wires the primitives.
module calc_inner (
    input  wire       clk,
    input  wire       locked,     // the clock is stable: held in reset until it is
    input  wire       rst_buf,
    input  wire       rx_buf,
    output wire       tx_bit,
    output wire [7:0] led
);
    wire rst_all;
    por_gen por (.clk(clk), .rst_buf(rst_buf | !locked), .rst_all(rst_all));

    // carry-free LFSR baud: bg16 = 16x baud, bg2 = bg16/8 (TX 2x baud).
    // 100 MHz (sysclk through the MMCM) -> /54 (TERMINAL 0x4F, 115741 baud);
    // 156.25 MHz user_clock -> /85 (TERMINAL 0x2D).
    wire baudtick16x, baudtick2x;
`ifdef USE_USERCLK
    lfsr_div #(.W(7),.TAPS(7'h60),.SEED(7'h7F),.TERMINAL(7'h2D)) bg16 (
`else
    lfsr_div #(.W(7),.TAPS(7'h60),.SEED(7'h7F),.TERMINAL(7'h4F)) bg16 (
`endif
        .clk(clk),.rst(rst_all),.ce(1'b1),.tick(baudtick16x));
    lfsr_div #(.W(4),.TAPS(4'hC),.SEED(4'hF),.TERMINAL(4'h9)) bg2 (
        .clk(clk),.rst(rst_all),.ce(baudtick16x),.tick(baudtick2x));

    // ---- RX: LFSR-timed receiver -> rx FIFO -> calc_core ----
    wire sin_sync, rxdone; wire [7:0] rxbyte;
    slib_input_sync sin_is (.CLK(clk),.RST(rst_all),.D(rx_buf),.Q(sin_sync));
    uart_rx_lfsr rxu (.clk(clk),.rst(rst_all),.rxtick(baudtick16x),.sin(sin_sync),
        .dout(rxbyte),.rxdone(rxdone));

    wire [7:0] rxf_dout, core_tx, txf_dout;
    wire core_rx_rd, rxf_empty, rxf_full, core_tx_stb, txf_empty, txf_full, txf_rd;
    wire rxf_nempty, txf_nfull;
    byte_fifo rxfifo (.clk(clk),.rst(rst_all),.wr(rxdone),.din(rxbyte),.full(rxf_full),
        .rd(core_rx_rd),.dout(rxf_dout),.empty(rxf_empty),.nempty(rxf_nempty),.nfull());
    calc_core #(.AUTOSTART(1'b1)) core (
        .clk(clk),.rst(rst_all),
        .rx_data(rxf_dout),.rx_valid(rxf_nempty),.rx_rd(core_rx_rd),
        .tx_byte(core_tx),.tx_stb(core_tx_stb),.tx_rdy(txf_nfull),.led(led));
    byte_fifo txfifo (.clk(clk),.rst(rst_all),.wr(core_tx_stb),.din(core_tx),.full(txf_full),
        .rd(txf_rd),.dout(txf_dout),.empty(txf_empty),.nempty(),.nfull(txf_nfull));

    // ---- TX: drain tx FIFO to uart_transmitter (FSM in its own submodule) ----
    wire [7:0] tx_din; wire txstart, txfinished;
    tx_drain txd (.clk(clk), .rst_all(rst_all), .txf_empty(txf_empty),
        .txf_dout(txf_dout), .txfinished(txfinished),
        .txf_rd(txf_rd), .txstart(txstart), .din(tx_din));
    uart_transmitter txu (.CLK(clk),.RST(rst_all),.TXCLK(baudtick2x),
        .TXSTART(txstart),.CLEAR(1'b0),.WLS(2'b11),.STB(1'b0),.PEN(1'b0),
        .EPS(1'b0),.SP(1'b0),.BC(1'b0),.DIN(tx_din),.TXFINISHED(txfinished),.SOUT(tx_bit));
endmodule

// Power-on reset: hold rst_all high for 31 clocks after config, then track
// the external reset.  Split out of `top` so the wrapper is purely structural.
module por_gen (
    input  wire clk,
    input  wire rst_buf,
    output wire rst_all
);
    reg [4:0] por_cnt = 5'h1F;
    always @(posedge clk) if (por_cnt != 5'd0) por_cnt <= por_cnt - 1'b1;
    assign rst_all = rst_buf | (por_cnt != 5'd0);
endmodule

// TX FIFO drain FSM: pop a byte from the tx FIFO and pulse the uart
// transmitter, one byte per TXFINISHED handshake.  (Was inline in `top`.)
module tx_drain (
    input  wire       clk,
    input  wire       rst_all,
    input  wire       txf_empty,
    input  wire [7:0] txf_dout,
    input  wire       txfinished,
    output reg        txf_rd,
    output reg        txstart,
    output reg  [7:0] din
);
    reg [1:0] tst;
    localparam T_IDLE=0,T_START=1,T_RUN=2,T_END=3;
    always @(posedge clk or posedge rst_all)
        if (rst_all) begin tst<=T_IDLE; din<=0; txstart<=0; txf_rd<=0; end
        else begin
            txstart<=1'b0; txf_rd<=1'b0;
            case (tst)
                T_IDLE:  if (!txf_empty) begin din<=txf_dout; txf_rd<=1'b1; txstart<=1'b1; tst<=T_START; end
                T_START: begin txstart<=1'b1; tst<=T_RUN; end
                T_RUN:   begin txstart<=1'b1; if (txfinished) tst<=T_END; end
                T_END:   tst<=T_IDLE;
            endcase
        end
endmodule
