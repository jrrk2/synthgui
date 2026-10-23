// Telegraph on Sonata: "JRRK" at 115200 8N1 on ser0_tx (C17), heartbeat on usrLed[0].
module top (
    input  wire       mainClk,
    input  wire       nrst,
    output wire       ser0_tx,
    output wire [7:0] usrLed
);
    wire clk_raw, clk, nrst_buf;
    IBUF ibuf_clk (.I(mainClk), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    IBUF ibuf_rst (.I(nrst), .O(nrst_buf));

    reg [24:0] heartbeat = 25'd0;     // 2^24 cycles at 25 MHz: ~1.5 Hz toggle
    always @(posedge clk) heartbeat <= heartbeat + 25'd1;

    wire ser_tx, led_idx0, led_idx1, led_rst;
    telegraph_core #(.CLK_HZ(25_000_000)) u_core (
        .clk(clk), .rst(~nrst_buf), .ser_tx(ser_tx),
        .led__0(led_idx0), .led__1(), .led__2(led_idx1), .led__3(led_rst));

    OBUF obuf_tx (.I(ser_tx), .O(ser0_tx));
    OBUF obuf_l0 (.I(heartbeat[24]), .O(usrLed[0]));
    OBUF obuf_l1 (.I(led_idx0),      .O(usrLed[1]));
    OBUF obuf_l2 (.I(led_idx1),      .O(usrLed[2]));
    OBUF obuf_l3 (.I(ser_tx),        .O(usrLed[3]));
    OBUF obuf_l4 (.I(1'b0), .O(usrLed[4]));
    OBUF obuf_l5 (.I(1'b0), .O(usrLed[5]));
    OBUF obuf_l6 (.I(1'b0), .O(usrLed[6]));
    OBUF obuf_l7 (.I(1'b0), .O(usrLed[7]));
endmodule
