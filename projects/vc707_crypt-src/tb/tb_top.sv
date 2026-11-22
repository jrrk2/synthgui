// The whole design, RTL or the mapped netlist (top_mapped.v): decodes the UART and checks
// the first report line says PASS.  DIV is the design's clocks per bit (FREQ_HZ / 115200).
module tb_top;
    parameter int DIV = 868;
    logic clk = 0;
    always #1 clk = !clk;
    wire tx;
    wire [7:0] led;
    top dut (.sysclk_p(clk), .sysclk_n(!clk), .rst(1'b0), .tx(tx), .led(led));
    string line = "", codes = "";
    longint unsigned cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;
    initial begin
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
                if ($test$plusargs("codes")) $display("bytes: %s", codes);
                if (line.substr(0, 4) == "crypt" && line.len() > 60) begin
                    $display("%s", line.substr(61, 64) == "PASS" ? "TB PASS" : "TB FAIL");
                    $finish;
                end
                line = "";
                codes = "";
            end else if (c != 8'h0d) begin
                line = {line, string'(c)};
                codes = {codes, $sformatf("%02x", c)};
            end
        end
    end
endmodule
