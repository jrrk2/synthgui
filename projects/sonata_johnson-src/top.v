// Johnson counter on the lowRISC Sonata board: 25 MHz mainClk, active-low nrst,
// the eight user LEDs.
module top (
    input wire mainClk,
    input wire nrst,
    output wire [7:0] usrLed
);
    wire clk_raw;
    wire clk;
    wire nrst_buf;
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
endmodule
