// STRETCH GOAL top: configurable-alphabet cracking service.  Same UART protocol as
// crack2_top, plus a "%<32 hex>" line that sets a 128-bit ASCII glyph mask (bit g set =>
// code g is in the alphabet).  When the mask is set, a one-shot scanner walks bits 0..127
// once and writes the set ones into a compact table code[0..ngl-1] (the "8-bit x N RAM");
// the engine (crack2_glyph_engine) then counts indices into that table, so no 128-bit
// priority encoder sits on the per-cycle path.  Default alphabet a..z.
//
// Kept as a stretch goal and a router-divergence demonstration (see crack2_glyph_divergence.log).
// Verified in simulation (OK a1 tries=0x900), but the engine's glyph table is an 896-bit flop
// vector read by wide muxes, which nextpnr's router cannot converge -- congestion bottoms out
// then climbs away.  The fix is a true RAM (LUTRAM) for the table; until then this does not
// produce a bitstream.  The shipped cracker is crack2_top.sv (fixed a..z, 100 MHz).
module top #(
    parameter int CLK_DIV = 10
) (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       rst,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led
);
    wire clk_raw, clk_mmcm, clk_fb, clk, locked, rst_buf, rx_buf;
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
    IBUF ibuf_rx  (.I(rx),  .O(rx_buf));

    wire       sout;
    wire [6:0] led_int;
    crack2_glyph_inner #(.FREQ_HZ(1000000000 / CLK_DIV)) inner (
        .clk(clk), .rst(rst_buf || !locked), .rx_buf(rx_buf), .tx(sout), .led(led_int));

    OBUF obuf_tx (.I(sout), .O(tx));
    OBUF o0 (.I(led_int[0]), .O(led[0])); OBUF o1 (.I(led_int[1]), .O(led[1]));
    OBUF o2 (.I(led_int[2]), .O(led[2])); OBUF o3 (.I(led_int[3]), .O(led[3]));
    OBUF o4 (.I(led_int[4]), .O(led[4])); OBUF o5 (.I(led_int[5]), .O(led[5]));
    OBUF o6 (.I(led_int[6]), .O(led[6])); OBUF o7 (.I(locked),      .O(led[7]));
endmodule

module crack2_glyph_inner #(
    parameter int FREQ_HZ = 100000000,
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int MAXLEN = 6,
    parameter int NG = 128,
    parameter int BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx_buf,
    output logic      tx,
    output wire [6:0] led
);
    logic [4:0] por = 5'h1F;
    always_ff @(posedge clk) por <= rst ? 5'h1F : por - (por != 5'd0);
    wire r = por != 5'd0;

    // ---- RX: carry-free LFSR receiver (16x baud) from vc707_calc ----
    wire baudtick16x, sin_sync, rxdone;
    wire [7:0] rxbyte;
    lfsr_div #(.W(7), .TAPS(7'h60), .SEED(7'h7F), .TERMINAL(7'h4F)) bg16 (
        .clk(clk), .rst(r), .ce(1'b1), .tick(baudtick16x));
    slib_input_sync sin_is (.CLK(clk), .RST(r), .D(rx_buf), .Q(sin_sync));
    uart_rx_lfsr rxu (.clk(clk), .rst(r), .rxtick(baudtick16x), .sin(sin_sync),
                      .dout(rxbyte), .rxdone(rxdone));

    function automatic logic [5:0] d64(input logic [7:0] ch);
        if (ch < 8'd58) return 6'(ch - 8'd46);
        else if (ch < 8'd91) return 6'(ch - 8'd53);
        else return 6'(ch - 8'd59);
    endfunction
    function automatic logic [3:0] hexv(input logic [7:0] ch);
        if (ch <= 8'd57) return 4'(ch - 8'd48);
        else if (ch <= 8'd70) return 4'(ch - 8'd55);
        else return 4'(ch - 8'd87);
    endfunction

    // default alphabet a..z, as a compact table
    function automatic logic [7*NG-1:0] code_az();
        code_az = '0;
        for (int j = 0; j < 26; j++) code_az[7*j +: 7] = 7'(97 + j);
    endfunction

    // ---- the search engine (configurable alphabet via the table) ----
    logic [127:0]   gmask = 128'h07FFFFFE000000000000000000000000;  // for reference/scan source
    logic [7*NG-1:0] code = code_az();
    logic [7:0]     ngl  = 8'd26;
    logic           building = 1'b0;
    logic [7:0]     bscan = '0, nbuilt = '0;

    logic         estart = 1'b0, pend = 1'b0;
    logic [63:0]  target, ptarget;
    logic [11:0]  salt, psalt;
    wire          edone, found;
    wire [8*MAXLEN-1:0] epw;
    wire [2:0]    epwlen;
    wire [31:0]   etried;
    crack2_glyph_engine #(.D(D), .ITER(ITER), .MAXLEN(MAXLEN), .NG(NG)) eng (
        .clk(clk), .start(estart), .target(target), .salt(salt),
        .code(code), .ngl(ngl),
        .done(edone), .found(found), .pw(epw), .pwlen(epwlen), .tried(etried));

    // ---- milliseconds elapsed, five BCD digits ----
    localparam int MSDIV = FREQ_HZ / 1000;
    logic                     timing = 1'b0;
    logic [$clog2(MSDIV)-1:0] msdiv = '0;
    logic [19:0]              msbcd = '0;
    function automatic logic [19:0] bcd_inc(input logic [19:0] b);
        logic carry;
        bcd_inc = b;
        carry   = 1'b1;
        for (int d = 0; d < 5; d++)
            if (carry) begin
                if (b[4*d +: 4] == 4'd9) bcd_inc[4*d +: 4] = 4'd0;
                else begin bcd_inc[4*d +: 4] = b[4*d +: 4] + 4'd1; carry = 1'b0; end
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

    // ---- line parser ----
    logic [127:0] acc = '0;
    logic [5:0]   nin = '0;
    logic         gcmd = 1'b0;

    localparam int L = 3 + MAXLEN + 7 + 8 + 4 + 5 + 2;
    logic [8*L-1:0] line;
    localparam int DIV = FREQ_HZ / BAUD;
    logic [$clog2(DIV)-1:0] baud = '0;
    logic [9:0]  shreg = '1;
    logic [3:0]  nbit = '0;
    logic [7:0]  nchar = '0;
    logic [1:0]  state = 2'd0;
    assign tx = shreg[0];

    always_ff @(posedge clk) begin
        estart <= 1'b0;
        if (timing && !edone) begin
            if (msdiv == $bits(msdiv)'(MSDIV - 1)) begin
                msdiv <= '0; msbcd <= bcd_inc(msbcd);
            end else msdiv <= msdiv + 1'b1;
        end

        // one-shot mask scanner: walk bits 0..NG-1, append the set ones to the table
        if (building) begin
            if (gmask[bscan]) begin
                code[7*nbuilt +: 7] <= 7'(bscan);
                nbuilt <= nbuilt + 8'd1;
            end
            if (bscan == 8'(NG - 1)) begin
                building <= 1'b0;
                ngl <= nbuilt + (gmask[bscan] ? 8'd1 : 8'd0);
            end
            bscan <= bscan + 8'd1;
        end

        if (r) begin
            state <= 2'd0; nin <= '0; gcmd <= 1'b0; nbit <= '0; shreg <= '1;
            timing <= 1'b0; building <= 1'b0; pend <= 1'b0;
        end else begin
            // a search deferred until the table finished building
            if (pend && !building) begin
                salt <= psalt; target <= ptarget; estart <= 1'b1;
                timing <= 1'b1; msdiv <= '0; msbcd <= '0; pend <= 1'b0; state <= 2'd1;
            end
            case (state)
            2'd0: if (rxdone) begin
                if (rxbyte == 8'h0a) begin
                    if (gcmd) begin
                        if (nin == 6'd32) begin           // 32 hex -> mask, then scan it
                            gmask  <= acc;
                            building <= 1'b1; bscan <= '0; nbuilt <= '0;
                        end
                    end else if (nin == 6'd13) begin
                        psalt   <= {acc[71:66], acc[77:72]};
                        ptarget <= acc[65:2];
                        pend    <= 1'b1;                  // fire when !building
                    end
                    nin <= '0; gcmd <= 1'b0;
                end else if (rxbyte == 8'h0d) begin
                end else if (nin == 6'd0 && !gcmd && rxbyte == 8'h25) begin
                    gcmd <= 1'b1;
                end else if (gcmd) begin
                    acc <= {acc[123:0], hexv(rxbyte)}; nin <= nin + 1'b1;
                end else begin
                    acc <= {acc[121:0], d64(rxbyte)};  nin <= nin + 1'b1;
                end
            end
            2'd1: if (edone && !estart && !pend) begin
                logic [8*MAXLEN-1:0] wf;
                for (int c = 0; c < MAXLEN; c++)
                    wf[8*c +: 8] = (epw[8*c +: 8] != 8'd0) ? epw[8*c +: 8] : 8'd32;
                timing <= 1'b0;
                line   <= {found ? "OK " : "NF ", wf, " tries=", hex32(etried),
                           " ms=", bcd5(msbcd), "\r\n"};
                nchar  <= 8'(L);
                state  <= 2'd2;
            end
            2'd2: if (baud != '0) baud <= baud - 1'b1;
                else begin
                    baud <= $bits(baud)'(DIV - 1);
                    if (nbit != '0) begin
                        shreg <= {1'b1, shreg[9:1]}; nbit <= nbit - 1'b1;
                    end else if (nchar != '0) begin
                        shreg <= {1'b1, line[8*L-1 -: 8], 1'b0};
                        line  <= line << 8; nchar <= nchar - 1'b1; nbit <= 4'd9;
                    end else state <= 2'd0;
                end
            default: ;
            endcase
        end
    end

    assign led = {4'b0, state == 2'd0, state == 2'd1, found};
endmodule
