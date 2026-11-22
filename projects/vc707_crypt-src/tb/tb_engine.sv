// crypt_engine against gen_crypt.py: one batch of N passwords, then the sum and first.
module tb_engine;
    parameter int D = 8;
    parameter int N = 256;
    logic clk = 0, start = 0;
    wire done;
    wire [63:0] sum, first;
    crypt_engine #(.D(D), .N(N)) eng (.clk(clk), .start(start), .done(done), .sum(sum), .first(first));
    always #1 clk = !clk;
    longint unsigned cycles = 0;
    initial begin
        repeat (4) @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;
        @(posedge clk);
        while (!done) begin
            @(posedge clk);
            cycles++;
        end
        $display("n=%0d sum=%016x first=%016x cycles=%0d", N, sum, first, cycles);
        $finish;
    end
endmodule
