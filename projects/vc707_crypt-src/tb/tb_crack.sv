// The crack top (RTL or mapped netlist), compiled with +define+CRACK_SIM so the search
// space is small: decodes the UART line and checks it recovered PWSTR and says PASS.
// DIV is the design's clocks per bit (FREQ_HZ / 115200).
module tb_crack;
    parameter int DIV = 868;
`include "crack_expect_sim.svh"
    logic clk = 0;
    always #1 clk = !clk;
    wire tx;
    wire [7:0] led;
    top dut (.sysclk_p(clk), .sysclk_n(!clk), .rst(1'b0), .tx(tx), .led(led));
    string line = "", want;
    longint unsigned cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;
    initial begin
        want = {"crack ", string'(HASHSTR), " -> \"", string'(PWSTR), "\" PASS"};
        forever begin
            logic [7:0] c;
            @(negedge tx);
            repeat (DIV / 2) @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                repeat (DIV) @(posedge clk);
                c[i] = tx;
            end
            repeat (DIV) @(posedge clk);
            if (c == 8'h0a) begin
                $display("%0d cycles: %s", cycles, line);
                $display("%s", line.substr(0, want.len() - 1) == want ? "TB PASS" : "TB FAIL");
                $finish;
            end else if (c != 8'h0d) line = {line, string'(c)};
        end
    end
endmodule
