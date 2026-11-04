// ICAP smoke test on the lowRISC Sonata (xc7a50t); see icap_smoke.v
module top (
    input  wire mainClk,
    output wire serial_tx,
    output wire [7:0] usrLed
);
    wire clk_raw, clk, tx, csib, rdwrb;
    wire [7:0] led;
    wire [31:0] i, o;
    IBUF ibuf_clk (.I(mainClk), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    icap_smoke core (.clk(clk), .tx(tx), .led(led), .icap_i(i), .icap_csib(csib), .icap_rdwrb(rdwrb), .icap_o(o));
    ICAPE2 #(.ICAP_WIDTH("X32")) icap (.CLK(clk), .CSIB(csib), .RDWRB(rdwrb), .I(i), .O(o));
    OBUF obuf_tx (.I(tx), .O(serial_tx));
    OBUF obuf0 (.I(led[0]), .O(usrLed[0]));
    OBUF obuf1 (.I(led[1]), .O(usrLed[1]));
    OBUF obuf2 (.I(led[2]), .O(usrLed[2]));
    OBUF obuf3 (.I(led[3]), .O(usrLed[3]));
    OBUF obuf4 (.I(led[4]), .O(usrLed[4]));
    OBUF obuf5 (.I(led[5]), .O(usrLed[5]));
    OBUF obuf6 (.I(led[6]), .O(usrLed[6]));
    OBUF obuf7 (.I(led[7]), .O(usrLed[7]));
endmodule
