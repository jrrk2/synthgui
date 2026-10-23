// Block RAM shapes on the Sonata board (XC7A50T: 75 RAMB36), each answering one
// question: does what comes out match what went in?  See bramtest.v for why.
// Ported from the VC707 bramtest; the results go to the LCD in place of the UART.
//
// One line per shape: its name, the bit positions that ever came back wrong
// (00000000 when none), and PASS / FAIL, or RUN until the shape has finished.
// The last line summarises: the number of shapes that passed.  The reset
// button runs the whole test again.
//
//   x1..x36   one RAMB36 at that width, written through A and read through B
//   x32       16K x 32 RAM;  x16R  8K x 16 ROM
//   x9b, x8   2048 deep: one RAMB18 (the Ethernet path's shapes)
//   x1L, x1LR 64K x 1 RAM / ROM: a cascaded RAMB36 pair
//   x2L       64K x 2 RAM:    the cascade, two lanes of it
// The mapper spends a RAMB36 on every bit of a 32-bit memory, so the VC707
// test's x32 ROM and its 64K x 32 RAM and ROM (about 32, 64 and 64 blocks) do
// not fit this part's 75; x16R, and x2L for the cascade, stand in for them.
// This build uses 73 of the 75.
module top (
    input wire mainClk,
    input wire nrst,
    output wire [7:0] usrLed,
    output wire lcd_rst,
    output wire lcd_dc,
    output wire lcd_copi,
    output wire lcd_clk,
    output wire lcd_cs,
    output wire lcd_backlight
);
    wire clk_raw, clk, nrst_buf;
    IBUF ibuf_clk (.I(mainClk), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    IBUF ibuf_rst (.I(nrst), .O(nrst_buf));

    // hold the shapes in reset for a while after the button, as the VC707 test does
    reg [15:0] rstcnt = 16'd0;
    wire rst = !rstcnt[15];
    always @(posedge clk)
        if (!nrst_buf) rstcnt <= 16'd0;
        else if (!rstcnt[15]) rstcnt <= rstcnt + 1'b1;

    localparam integer N = 13;
    wire [N-1:0] done, ok;
    wire [0:0]  bad0;
    wire [1:0]  bad1;
    wire [3:0]  bad2;
    wire [8:0]  bad3;
    wire [17:0] bad4;
    wire [35:0] bad5;
    wire [31:0] bad6;
    wire [15:0] bad7;
    wire [8:0]  bad8;
    wire [7:0]  bad9;
    wire [0:0]  bad10, bad11;
    wire [1:0]  bad12;

    bram_case #(.WIDTH(1),  .AW(15), .ROM(0)) c0 (.clk(clk), .rst(rst), .done(done[0]), .ok(ok[0]), .badbits(bad0));
    bram_case #(.WIDTH(2),  .AW(14), .ROM(0)) c1 (.clk(clk), .rst(rst), .done(done[1]), .ok(ok[1]), .badbits(bad1));
    bram_case #(.WIDTH(4),  .AW(13), .ROM(0)) c2 (.clk(clk), .rst(rst), .done(done[2]), .ok(ok[2]), .badbits(bad2));
    bram_case #(.WIDTH(9),  .AW(12), .ROM(0)) c3 (.clk(clk), .rst(rst), .done(done[3]), .ok(ok[3]), .badbits(bad3));
    bram_case #(.WIDTH(18), .AW(11), .ROM(0)) c4 (.clk(clk), .rst(rst), .done(done[4]), .ok(ok[4]), .badbits(bad4));
    bram_case #(.WIDTH(36), .AW(10), .ROM(0)) c5 (.clk(clk), .rst(rst), .done(done[5]), .ok(ok[5]), .badbits(bad5));
    bram_case #(.WIDTH(32), .AW(14), .ROM(0)) c6 (.clk(clk), .rst(rst), .done(done[6]), .ok(ok[6]), .badbits(bad6));
    bram_case #(.WIDTH(16), .AW(13), .ROM(1)) c7 (.clk(clk), .rst(rst), .done(done[7]), .ok(ok[7]), .badbits(bad7));
    bram_case #(.WIDTH(9),  .AW(11), .ROM(0)) c8 (.clk(clk), .rst(rst), .done(done[8]), .ok(ok[8]), .badbits(bad8));
    bram_case #(.WIDTH(8),  .AW(11), .ROM(0)) c9 (.clk(clk), .rst(rst), .done(done[9]), .ok(ok[9]), .badbits(bad9));
    bram_case #(.WIDTH(1),  .AW(16), .ROM(0)) c10 (.clk(clk), .rst(rst), .done(done[10]), .ok(ok[10]), .badbits(bad10));
    bram_case #(.WIDTH(1),  .AW(16), .ROM(1), .INITFILE("rom64k_w1.hex")) c11 (.clk(clk), .rst(rst), .done(done[11]), .ok(ok[11]), .badbits(bad11));
    bram_case #(.WIDTH(2),  .AW(16), .ROM(0)) c12 (.clk(clk), .rst(rst), .done(done[12]), .ok(ok[12]), .badbits(bad12));

    wire all_done = &done;
    wire all_ok = &ok;
    wire [3:0] passed = ok[0] + ok[1] + ok[2] + ok[3] + ok[4] + ok[5] + ok[6] + ok[7] +
                        ok[8] + ok[9] + ok[10] + ok[11] + ok[12];

    // LEDs: the shapes grouped as in the VC707 test; the top LED is "all done"
    wire [7:0] led_all = {all_done, ok[12:10], &ok[9:5], &ok[4:2], &ok[1:0]};
    OBUF obuf0 (.I(led_all[0]), .O(usrLed[0]));
    OBUF obuf1 (.I(led_all[1]), .O(usrLed[1]));
    OBUF obuf2 (.I(led_all[2]), .O(usrLed[2]));
    OBUF obuf3 (.I(led_all[3]), .O(usrLed[3]));
    OBUF obuf4 (.I(led_all[4]), .O(usrLed[4]));
    OBUF obuf5 (.I(led_all[5]), .O(usrLed[5]));
    OBUF obuf6 (.I(led_all[6]), .O(usrLed[6]));
    OBUF obuf7 (.I(led_all[7]), .O(usrLed[7]));

    // status of shape i: RUN until it is done, then PASS or FAIL
    function [1:0] st(input d, input o);
        st = !d ? 2'd3 : o ? 2'd1 : 2'd2;
    endfunction

    wire [15*32-1:0] words = {
        32'h0,                                   // line 14, unused
        {28'h0, passed},                         // ALL
        {30'h0, bad12}, {31'h0, bad11}, {31'h0, bad10}, {24'h0, bad9}, {23'h0, bad8},
        {16'h0, bad7}, bad6, bad5[31:0], {14'h0, bad4}, {23'h0, bad3}, {28'h0, bad2},
        {30'h0, bad1}, {31'h0, bad0}
    };
    wire [15*2-1:0] status = {
        2'd0,
        all_done ? (all_ok ? 2'd1 : 2'd2) : 2'd3,
        st(done[12], ok[12]), st(done[11], ok[11]), st(done[10], ok[10]), st(done[9], ok[9]),
        st(done[8], ok[8]), st(done[7], ok[7]), st(done[6], ok[6]), st(done[5], ok[5]),
        st(done[4], ok[4]), st(done[3], ok[3]), st(done[2], ok[2]), st(done[1], ok[1]),
        st(done[0], ok[0])
    };

    wire l_rst, l_dc, l_copi, l_clk, l_cs, l_bl;
    lcd_dbg #(
        .TITLE("SONATA BRAM TEST    "),
        .LABELS({"x1  ", "x2  ", "x4  ", "x9  ", "x18 ", "x36 ", "x32 ", "x16R",
                 "x9b ", "x8  ", "x1L ", "x1LR", "x2L ", "ALL ", "    "})
    ) lcd (
        .clk(clk), .rst(!nrst_buf), .words(words), .status(status),
        .lcd_rst(l_rst), .lcd_dc(l_dc), .lcd_copi(l_copi), .lcd_clk(l_clk),
        .lcd_cs(l_cs), .lcd_backlight(l_bl)
    );

    OBUF o_rst (.I(l_rst), .O(lcd_rst));
    OBUF o_dc (.I(l_dc), .O(lcd_dc));
    OBUF o_copi (.I(l_copi), .O(lcd_copi));
    OBUF o_clk (.I(l_clk), .O(lcd_clk));
    OBUF o_cs (.I(l_cs), .O(lcd_cs));
    OBUF o_bl (.I(l_bl), .O(lcd_backlight));
endmodule
