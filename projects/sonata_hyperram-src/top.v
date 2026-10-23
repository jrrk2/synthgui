// 8 MB RAM test of the Sonata board's HyperRAM (W956D8MBYA), through LiteX's HyperRAM core; the
// results on the LCD.  See hr_ramtest.v for what is tested and sonata-lib/gen_hyperram.py for the core.
//
//   ID0 / ID1  the device's identification registers (0C81 / 0001 for the W956D8MBYA)
//   CR0        configuration register 0 read back after writing it (8FF7: 4 clocks, variable latency)
//   PASS       completed loops: write, read, write the complement, read, of all 8 MB
//   PHAS       0 write, 1 read, 2 write complement, 3 read complement
//   ADDR       byte address being tested
//   ERRS       words read back wrong;  FADR / FEXP / FGOT: where, what was expected, what came back
//   XORS       every bit position that was ever wrong (a stuck or crossed data line shows here)
//   TOUT       times the controller hung and was restarted
//   PCYC       80 MHz cycles the last phase took (2M words)
//   TEST       RUN until the first full loop, then PASS, or FAIL on any error or restart
// The reset button runs it all again.  LEDs: 0 running, 1 loop done, 2 errors, 3 restarts,
// 4..7 the low bits of the pass count.
module top (
    input wire mainClk,
    input wire nrst,
    output wire [7:0] usrLed,
    output wire lcd_rst,
    output wire lcd_dc,
    output wire lcd_copi,
    output wire lcd_clk,
    output wire lcd_cs,
    output wire lcd_backlight,
    inout wire [7:0] hyperram_dq,
    inout wire hyperram_rwds,
    output wire hyperram_ckp,
    output wire hyperram_ckn,
    output wire hyperram_nrst,
    output wire hyperram_cs
);
    wire clk_in, nrst_buf, locked, clk, clk25;
    IBUF ibuf_clk (.I(mainClk), .O(clk_in));
    IBUF ibuf_rst (.I(nrst), .O(nrst_buf));
    clkgen_sonata clkgen (.clk_in(clk_in), .rst(!nrst_buf), .clk80(clk), .clk25(clk25), .locked(locked));

    // reset: the button or the MMCM out of lock, released in step with each clock
    reg [2:0] rst_q = 3'b111;
    always @(posedge clk) rst_q <= {rst_q[1:0], !locked};
    wire rst = rst_q[2];
    reg [2:0] rst25_q = 3'b111;
    always @(posedge clk25) rst25_q <= {rst25_q[1:0], !locked};
    wire rst25 = rst25_q[2];

    // ---- HyperRAM pads
    wire hr_rst_n, hr_cs_n, hr_ck_p, hr_ck_n, hr_dq_oe, hr_rwds_o, hr_rwds_oe, hr_rwds_i;
    wire [7:0] hr_dq_o, hr_dq_i;

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : dq
            IOBUF iobuf (.IO(hyperram_dq[i]), .I(hr_dq_o[i]), .T(!hr_dq_oe), .O(hr_dq_i[i]));
        end
    endgenerate
    IOBUF iobuf_rwds (.IO(hyperram_rwds), .I(hr_rwds_o), .T(!hr_rwds_oe), .O(hr_rwds_i));
    OBUF obuf_ckp (.I(hr_ck_p), .O(hyperram_ckp));
    OBUF obuf_ckn (.I(hr_ck_n), .O(hyperram_ckn));
    OBUF obuf_nrst (.I(hr_rst_n), .O(hyperram_nrst));
    OBUF obuf_cs (.I(hr_cs_n), .O(hyperram_cs));

    // ---- the test
    wire [15:0] id0, id1, cr0, passes, touts;
    wire [1:0] phase;
    wire [20:0] idx;
    wire [31:0] errs, first_adr, first_exp, first_got, xors, pcyc;
    wire running, looped;

    hr_ramtest ramtest (
        .clk(clk), .rst(rst), .cr0_wr(16'h8FF7),
        .hr_rst_n(hr_rst_n), .hr_cs_n(hr_cs_n), .hr_ck_p(hr_ck_p), .hr_ck_n(hr_ck_n),
        .hr_dq_o(hr_dq_o), .hr_dq_i(hr_dq_i), .hr_dq_oe(hr_dq_oe),
        .hr_rwds_o(hr_rwds_o), .hr_rwds_i(hr_rwds_i), .hr_rwds_oe(hr_rwds_oe),
        .id0(id0), .id1(id1), .cr0(cr0), .passes(passes), .phase(phase), .idx(idx),
        .errs(errs), .first_adr(first_adr), .first_exp(first_exp), .first_got(first_got),
        .xors(xors), .touts(touts), .pcyc(pcyc), .running(running), .looped(looped)
    );

    wire bad = (errs != 32'h0) || (touts != 16'h0);

    wire [7:0] led_int = {passes[3:0], touts != 16'h0, errs != 32'h0, looped, running};
    OBUF obuf_led0 (.I(led_int[0]), .O(usrLed[0]));
    OBUF obuf_led1 (.I(led_int[1]), .O(usrLed[1]));
    OBUF obuf_led2 (.I(led_int[2]), .O(usrLed[2]));
    OBUF obuf_led3 (.I(led_int[3]), .O(usrLed[3]));
    OBUF obuf_led4 (.I(led_int[4]), .O(usrLed[4]));
    OBUF obuf_led5 (.I(led_int[5]), .O(usrLed[5]));
    OBUF obuf_led6 (.I(led_int[6]), .O(usrLed[6]));
    OBUF obuf_led7 (.I(led_int[7]), .O(usrLed[7]));

    // ---- the display, on its own 25 MHz clock; the words are sampled across, which is fine for
    // numbers that are read by eye
    wire [15*32-1:0] words = {
        32'h0,
        {31'h0, looped},                       // TEST
        pcyc,
        {16'h0, touts},
        xors, first_got, first_exp, first_adr, errs,
        {9'h0, idx, 2'b00},                    // ADDR (byte)
        {30'h0, phase}, {16'h0, passes},
        {16'h0, cr0}, {16'h0, id1}, {16'h0, id0}
    };
    wire [1:0] s_errs = (errs != 32'h0) ? 2'd2 : 2'd0;           // FAIL beside ERRS and TOUT when non-zero
    wire [1:0] s_tout = (touts != 16'h0) ? 2'd2 : 2'd0;
    wire [1:0] s_test = !running ? 2'd3 : bad ? 2'd2 : looped ? 2'd1 : 2'd3;   // RUN / FAIL / PASS
    wire [15*2-1:0] status = {2'd0, s_test, 2'd0, s_tout, 8'h0, s_errs, 12'h0};
    reg [15*32-1:0] words_q;
    reg [15*2-1:0] status_q;
    always @(posedge clk25) begin
        words_q <= words;
        status_q <= status;
    end

    wire l_rst, l_dc, l_copi, l_clk, l_cs, l_bl;
    lcd_dbg #(
        .TITLE("SONATA HYPERRAM 8MB "),
        .LABELS({"ID0 ", "ID1 ", "CR0 ", "PASS", "PHAS", "ADDR", "ERRS", "FADR", "FEXP", "FGOT",
                 "XORS", "TOUT", "PCYC", "TEST", "    "})
    ) lcd (
        .clk(clk25), .rst(rst25), .words(words_q), .status(status_q),
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
