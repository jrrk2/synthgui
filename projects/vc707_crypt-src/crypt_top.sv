// vc707_crypt: UNIX V7 crypt(3) at speed on the VC707, checked against libcrypt.
//
// The 200 MHz sysclk drives an MMCM (VCO 1 GHz) whose CLKOUT0 / CLK_DIV is the one
// clock.  crypt_engine hashes NHASH passwords per batch; after each the UART
// (115200 8N1) prints password(0)'s hash, the batch's sum, PASS when both are
// libcrypt's (crypt_expect.svh) and the running pass / fail counts, then starts
// the next batch.  LED 0 blinks per batch, LED 1 is any failure, LED 7 locked.
module top #(
    parameter int CLK_DIV = 10,  // MMCM CLKOUT0 divide: 1000 MHz / CLK_DIV
    parameter int D = 8,
    parameter int ITER = 25
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
    wire [7:0] led_int;
    crypt_inner #(.FREQ_HZ(1000000000 / CLK_DIV), .D(D), .ITER(ITER)) inner (
        .clk(clk), .rst(rst_buf || !locked), .tx(sout), .led(led_int[6:0]));
    assign led_int[7] = locked;

    OBUF obuf_tx (.I(sout), .O(tx));
    OBUF o0 (.I(led_int[0]), .O(led[0])); OBUF o1 (.I(led_int[1]), .O(led[1]));
    OBUF o2 (.I(led_int[2]), .O(led[2])); OBUF o3 (.I(led_int[3]), .O(led[3]));
    OBUF o4 (.I(led_int[4]), .O(led[4])); OBUF o5 (.I(led_int[5]), .O(led[5]));
    OBUF o6 (.I(led_int[6]), .O(led[6])); OBUF o7 (.I(led_int[7]), .O(led[7]));
endmodule

module crypt_inner #(
    parameter int FREQ_HZ = 125000000,
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst,
    output logic      tx,
    output wire [6:0] led
);
`include "crypt_expect.svh"

    // reset held a while after the button / lock
    logic [4:0] por = 5'h1F;
    always_ff @(posedge clk) por <= rst ? 5'h1F : por - (por != 5'd0);
    wire r = por != 5'd0;

    logic        start = 1'b0;
    wire         done;
    wire  [63:0] sum, first;
    crypt_engine #(.D(D), .ITER(ITER), .N(NHASH)) eng (
        .clk(clk), .start(start), .done(done), .sum(sum), .first(first));

    function automatic logic [7:0] hexc(input logic [3:0] x);
        return x < 4'd10 ? 8'(x) + 8'd48 : 8'(x) + 8'd87;
    endfunction
    function automatic logic [7:0] b64c(input logic [5:0] x);
        if (x < 6'd12) return 8'(x) + 8'd46;
        if (x < 6'd38) return 8'(x) + 8'd53;
        return 8'(x) + 8'd59;
    endfunction
    function automatic logic [8*16-1:0] hex64(input logic [63:0] x);
        for (int i = 0; i < 16; i++) hex64[8 * i +: 8] = hexc(x[4 * i +: 4]);
    endfunction
    function automatic logic [8*8-1:0] hex32(input logic [31:0] x);
        for (int i = 0; i < 8; i++) hex32[8 * i +: 8] = hexc(x[4 * i +: 4]);
    endfunction
    function automatic logic [8*11-1:0] hash11(input logic [63:0] x);
        logic [65:0] b;
        b = {x, 2'b00};
        for (int i = 0; i < 11; i++) hash11[8 * i +: 8] = b64c(b[6 * i +: 6]);
    endfunction

    // crypt("ZKuk1fZK","ab") = abpDHYAVhIFvw  sum e545a456ca810a94 PASS  pass 0000002a fail 00000000
    localparam int L = 7 + 8 + 3 + 2 + 5 + 13 + 6 + 16 + 1 + 4 + 7 + 8 + 6 + 8 + 2;
    logic [8*L-1:0] line;
    logic [31:0]    npass = '0, nfail = '0;
    wire            ok = sum == EXPECT_SUM && first == EXPECT_FIRST;

    // 8N1 transmitter, the line shifted out from its first character
    localparam int DIV = FREQ_HZ / BAUD;
    logic [$clog2(DIV)-1:0] baud = '0;
    logic [9:0]  shreg = '1;
    logic [3:0]  nbit = '0;
    logic [7:0]  nchar = '0;
    logic [1:0]  state = 2'd0;  // 0 hashing, 1 printing, 2 next batch
    assign tx = shreg[0];

    always_ff @(posedge clk) begin
        start <= 1'b0;
        if (r) begin
            state <= 2'd2;
            nbit  <= '0;
            shreg <= '1;
        end else case (state)
        2'd0: if (done && !start) begin
            if (ok) npass <= npass + 1'b1;
            else nfail <= nfail + 1'b1;
            line <= {"crypt(\"", PW0, "\",\"", SALT, "\") = ", SALT, hash11(first),
                     "  sum ", hex64(sum), " ", ok ? "PASS" : "FAIL",
                     "  pass ", hex32(ok ? npass + 1'b1 : npass),
                     " fail ", hex32(ok ? nfail : nfail + 1'b1), "\r\n"};
            nchar <= 8'(L);
            state <= 2'd1;
        end
        2'd1: if (baud != '0) baud <= baud - 1'b1;
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
                end else state <= 2'd2;
            end
        default: begin
            start <= 1'b1;
            state <= 2'd0;
        end
        endcase
    end

    logic [3:0] blink = '0;
    always_ff @(posedge clk) if (start) blink <= blink + 1'b1;
    assign led = {5'b0, nfail != '0, blink[0]};
endmodule
