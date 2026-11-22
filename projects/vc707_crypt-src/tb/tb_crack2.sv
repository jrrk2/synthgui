// crack2 top (RTL or netlist): bit-bang a crypt line into rx, decode the reply, check it.
// BIT is the design's clocks per bit (FREQ_HZ / 115200).  c2vec.svh gives the line and word.
module tb_crack2;
    parameter int BIT = 868;
`include "c2vec.svh"
    logic clk = 0;
    always #1 clk = !clk;
    logic rxl = 1'b1;
    wire tx;
    wire [7:0] led;
    top dut (.sysclk_p(clk), .sysclk_n(!clk), .rst(1'b0), .rx(rxl), .tx(tx), .led(led));

    task send_byte(input logic [7:0] b);
        rxl = 1'b0; repeat (BIT) @(posedge clk);             // start
        for (int i = 0; i < 8; i++) begin rxl = b[i]; repeat (BIT) @(posedge clk); end
        rxl = 1'b1; repeat (BIT) @(posedge clk);             // stop
    endtask

    task send_str(input string s);
        for (int i = 0; i < s.len(); i++) send_byte(8'(s[i]));
    endtask

    string line = "", want;
    initial begin
        repeat (200) @(posedge clk);
`ifdef GLYPHTEST
        // set the alphabet to a..z plus 0..9, then crack a digit-bearing password
        send_str("%07FFFFFE0000000003FF000000000000");
        send_byte(8'h0a);
        repeat (200) @(posedge clk);
`endif
        for (int i = 0; i < 13; i++) send_byte(C2_LINE[8*(12-i) +: 8]);  // 13 chars, first first
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
