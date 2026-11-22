module tb_c2beng;
    parameter int MAXLEN = 6, D = 8;
`include "c2vec.svh"
    logic clk = 0; always #1 clk = !clk;
    logic start = 0; wire done, found;
    wire [8*MAXLEN-1:0] pw; wire [2:0] pwlen; wire [31:0] tried;
    logic [127:0] gm = '0;
    crack2_bram_engine #(.D(D), .MAXLEN(MAXLEN)) eng (
        .clk(clk), .start(start), .target(C2_TARGET), .salt(C2_SALT), .gmask(gm),
        .done(done), .found(found), .pw(pw), .pwlen(pwlen), .tried(tried));
    initial begin
        string got = "";
        for (int ch=0; ch<128; ch++)
            if ((ch>=48&&ch<=57)||(ch>=65&&ch<=90)||(ch>=97&&ch<=122)) gm[ch]=1'b1; // alnum
        repeat (4) @(posedge clk);
        start <= 1; @(posedge clk); start <= 0;
        wait (done);
        for (int c=0;c<int'(pwlen);c++) got={got,string'(pw[8*(MAXLEN-1-c)+:8])};
        $display("found=%b pwlen=%0d tried=%0d pw=%s", found, pwlen, tried, got);
        $display("%s", (found && got==string'(C2_PW)) ? "TB PASS":"TB FAIL");
        $finish;
    end
endmodule
