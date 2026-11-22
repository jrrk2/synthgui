// crack2_glyph_inner: drive the UART directly (no MMCM/IO primitives).  Send a "%<mask>" line
// to set an alnum alphabet, scan it, then a crypt line; decode the reply and check it.
module tb_c2ginner;
    parameter int BIT = 868;            // FREQ_HZ/BAUD = 100e6/115200
`include "c2vec.svh"
    logic clk = 0;
    always #1 clk = !clk;
    logic rst = 1'b1, rxl = 1'b1;
    wire tx; wire [6:0] led;
    crack2_glyph_inner dut (.clk(clk), .rst(rst), .rx_buf(rxl), .tx(tx), .led(led));

    task send_byte(input logic [7:0] b);
        rxl = 1'b0; repeat (BIT) @(posedge clk);
        for (int i = 0; i < 8; i++) begin rxl = b[i]; repeat (BIT) @(posedge clk); end
        rxl = 1'b1; repeat (BIT) @(posedge clk);
    endtask
    task send_str(input string s);
        for (int i = 0; i < s.len(); i++) send_byte(8'(s[i]));
    endtask

    string line = "", want;
    initial begin
        repeat (100) @(posedge clk); rst = 1'b0; repeat (100) @(posedge clk);
        send_str("%07fffffe07fffffe03ff000000000000");  // alnum, lowercase hex (as the harness sends)
        send_byte(8'h0a);
        repeat (400) @(posedge clk);                    // let the scanner finish (<=128 cycles)
        for (int i = 0; i < 13; i++) send_byte(C2_LINE[8*(12-i) +: 8]);
        send_byte(8'h0a);
        want = {"OK ", string'(C2_PW)};
        forever begin
            logic [7:0] c;
            @(negedge tx);
            repeat (BIT / 2) @(posedge clk);
            for (int i = 0; i < 8; i++) begin repeat (BIT) @(posedge clk); c[i] = tx; end
            repeat (BIT) @(posedge clk);
            if (c == 8'h0a) begin
                $display("reply: %s", line);
                $display("%s", line.substr(0, want.len() - 1) == want ? "TB PASS" : "TB FAIL");
                $finish;
            end else if (c != 8'h0d) line = {line, string'(c)};
        end
    end
endmodule
