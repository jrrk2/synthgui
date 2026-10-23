// Sonata: Johnson counter on the LEDs, its state and a few counters on the LCD.
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
    wire [7:0] led_int;

    IBUF ibuf_clk (.I(mainClk), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    IBUF ibuf_rst (.I(nrst), .O(nrst_buf));

    counter25_core core (.clk(clk), .rst(~nrst_buf), .led(led_int));

    OBUF obuf0 (.I(led_int[0]), .O(usrLed[0]));
    OBUF obuf1 (.I(led_int[1]), .O(usrLed[1]));
    OBUF obuf2 (.I(led_int[2]), .O(usrLed[2]));
    OBUF obuf3 (.I(led_int[3]), .O(usrLed[3]));
    OBUF obuf4 (.I(led_int[4]), .O(usrLed[4]));
    OBUF obuf5 (.I(led_int[5]), .O(usrLed[5]));
    OBUF obuf6 (.I(led_int[6]), .O(usrLed[6]));
    OBUF obuf7 (.I(led_int[7]), .O(usrLed[7]));

    // something to look at
    reg [31:0] cnt = 32'h0;
    reg [24:0] sub = 25'd0;
    reg [31:0] sec = 32'h0;
    reg [31:0] lfsr = 32'h1;
    always @(posedge clk) begin
        cnt <= cnt + 32'h1;
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        if (sub == 25'd24_999_999) begin
            sub <= 25'd0;
            sec <= sec + 32'h1;
        end else sub <= sub + 25'd1;
    end

    wire [15*32-1:0] words = {
        {10{32'h0}},
        {31'h0, nrst_buf},
        lfsr,
        {24'h0, led_int},
        sec,
        cnt
    };

    wire l_rst, l_dc, l_copi, l_clk, l_cs, l_bl;
    lcd_dbg #(
        .TITLE("SONATA  DEBUG       "),
        .LABELS({"CNT ", "SEC ", "LED ", "LFSR", "NRST", {10{"    "}}})
    ) lcd (
        .clk(clk), .rst(~nrst_buf), .words(words), .status(30'd0),
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
