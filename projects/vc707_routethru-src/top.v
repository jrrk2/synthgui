// Route-through test: fabric-fed carry DI inputs (the bypass pin instead of a
// buffer LUT) and two fabric-fed flip-flops in one slice position (the main
// FF through the idle LUT as a route-through).  The LFSR feeds adders whose
// DI inputs are flop outputs, and flop-to-flop shift registers; two of those
// flops are pinned into one position by preplaced.txt.  LVS checks the
// bitstream against the netlist.
module top (
    input wire sysclk_p,
    input wire sysclk_n,
    input wire rst,
    output wire [7:0] led
);
    wire clk_raw, clk, rst_buf;
    wire [7:0] led_int;

    IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVDS"))
        ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    IBUF ibuf_rst (.I(rst), .O(rst_buf));

    routethru_core core (.clk(clk), .rst(rst_buf), .led(led_int));

    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : g_obuf
        OBUF obuf (.I(led_int[i]), .O(led[i]));
    end endgenerate
endmodule
