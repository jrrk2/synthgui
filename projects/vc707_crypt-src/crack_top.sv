// vc707_crack: recover a short monocase password from its hashed /etc/passwd line, on
// the FPGA, to show why it is a bad password.  crack_engine sweeps the 26^PWLEN
// lowercase strings against the hashed line in crack_expect.svh; when it finds the one
// whose crypt hash matches, the UART (115200 8N1) prints the recovered word, the number
// of guesses, and how long it took.  LED 0 is found, LED 1 is the search finished, LED 7
// locked.  Same MMCM and clock as crypt_top; the retimed engine does one guess a cycle.
module top #(
    parameter int CLK_DIV = 10  // MMCM CLKOUT0 divide: 1000 MHz / CLK_DIV
) (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       rst,
    output wire       tx,
    output wire [7:0] led
);
    wire clk_raw, clk_mmcm, clk_fb, clk, locked, rst_buf;
    IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVDS"))
        ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_raw));
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(5.000), .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(CLK_DIV), .CLKOUT0_PHASE(0.000), .CLKOUT0_DUTY_CYCLE(0.500),
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
    IBUF ibuf_rst (.I(rst), .O(rst_buf));

    wire       sout;
    wire [6:0] led_int;
    crack_inner #(.FREQ_HZ(1000000000 / CLK_DIV)) inner (
        .clk(clk), .rst(rst_buf || !locked), .tx(sout), .led(led_int));

    OBUF obuf_tx (.I(sout), .O(tx));
    OBUF o0 (.I(led_int[0]), .O(led[0])); OBUF o1 (.I(led_int[1]), .O(led[1]));
    OBUF o2 (.I(led_int[2]), .O(led[2])); OBUF o3 (.I(led_int[3]), .O(led[3]));
    OBUF o4 (.I(led_int[4]), .O(led[4])); OBUF o5 (.I(led_int[5]), .O(led[5]));
    OBUF o6 (.I(led_int[6]), .O(led[6])); OBUF o7 (.I(locked),      .O(led[7]));
endmodule

module crack_inner #(
    parameter int FREQ_HZ = 100000000,
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst,
    output logic      tx,
    output wire [6:0] led
);
`ifdef CRACK_SIM
  `include "crack_expect_sim.svh"  // a small lowercase space, so simulation finishes
`else
  `include "crack_expect.svh"
`endif

    logic [4:0] por = 5'h1F;
    always_ff @(posedge clk) por <= rst ? 5'h1F : por - (por != 5'd0);
    wire r = por != 5'd0;

    logic                  start = 1'b0;
    wire                   done, found;
    wire [8*PWLEN-1:0]     pw;
    wire [31:0]            tried;
    crack_engine #(.D(D), .ITER(ITER), .PWLEN(PWLEN), .TARGET(TARGET)) eng (
        .clk(clk), .start(start), .done(done), .found(found), .pw(pw), .tried(tried));

    // milliseconds elapsed while the search runs, as five BCD digits (d0 the units)
    localparam int MSDIV = FREQ_HZ / 1000;
    logic                   timing = 1'b0;
    logic [$clog2(MSDIV)-1:0] msdiv = '0;
    logic [19:0]            msbcd = '0;
    function automatic logic [19:0] bcd_inc(input logic [19:0] b);
        logic carry;
        bcd_inc = b;
        carry   = 1'b1;
        for (int d = 0; d < 5; d++)
            if (carry) begin
                if (b[4*d +: 4] == 4'd9) bcd_inc[4*d +: 4] = 4'd0;
                else begin
                    bcd_inc[4*d +: 4] = b[4*d +: 4] + 4'd1;
                    carry = 1'b0;
                end
            end
    endfunction

    function automatic logic [7:0] hexc(input logic [3:0] x);
        return x < 4'd10 ? 8'(x) + 8'd48 : 8'(x) + 8'd87;
    endfunction
    function automatic logic [8*8-1:0] hex32(input logic [31:0] x);
        for (int i = 0; i < 8; i++) hex32[8 * i +: 8] = hexc(x[4 * i +: 4]);
    endfunction
    function automatic logic [8*5-1:0] bcd5(input logic [19:0] b);
        for (int d = 0; d < 5; d++) bcd5[8 * d +: 8] = 8'd48 + 8'(b[4 * d +: 4]);
    endfunction

    // crack abP3wiLasumeg -> "vienna" PASS  tries 0x12640c5e  03089 ms
    localparam int L = 6 + 13 + 5 + PWLEN + 2 + 4 + 10 + 8 + 2 + 5 + 5;
    logic [8*L-1:0] line;

    localparam int DIV = FREQ_HZ / BAUD;
    logic [$clog2(DIV)-1:0] baud = '0;
    logic [9:0]  shreg = '1;
    logic [3:0]  nbit = '0;
    logic [7:0]  nchar = '0;
    logic [1:0]  state = 2'd0;  // 0 arm, 1 searching, 2 printing, 3 idle
    assign tx = shreg[0];

    always_ff @(posedge clk) begin
        start <= 1'b0;
        if (timing && !done) begin
            if (msdiv == $bits(msdiv)'(MSDIV - 1)) begin
                msdiv <= '0;
                msbcd <= bcd_inc(msbcd);
            end else msdiv <= msdiv + 1'b1;
        end
        if (r) begin
            state  <= 2'd0;
            nbit   <= '0;
            shreg  <= '1;
            timing <= 1'b0;
            msdiv  <= '0;
            msbcd  <= '0;
        end else case (state)
        2'd0: begin
            start  <= 1'b1;
            timing <= 1'b1;
            state  <= 2'd1;
        end
        2'd1: if (done && !start) begin
            timing <= 1'b0;
            line   <= {"crack ", HASHSTR, " -> \"", found ? pw : {PWLEN{8'h2D}},
                       "\" ", found ? "PASS" : "FAIL", "  tries 0x", hex32(tried),
                       "  ", bcd5(msbcd), " ms\r\n"};
            nchar  <= 8'(L);
            state  <= 2'd2;
        end
        2'd2: if (baud != '0) baud <= baud - 1'b1;
            else begin
                baud <= $bits(baud)'(DIV - 1);
                if (nbit != '0) begin
                    shreg <= {1'b1, shreg[9:1]};
                    nbit  <= nbit - 1'b1;
                end else if (nchar != '0) begin
                    shreg <= {1'b1, line[8*L-1 -: 8], 1'b0};
                    line  <= line << 8;
                    nchar <= nchar - 1'b1;
                    nbit  <= 4'd9;
                end else state <= 2'd3;
            end
        default: ;  // done: one search, one line
        endcase
    end

    assign led = {4'b0, state == 2'd3, done, found};
endmodule
