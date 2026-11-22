// crack2_engine on its own: drive one (target, salt) from c2vec.svh, check the recovery.
module tb_c2eng;
    parameter int MAXLEN = 6;
    parameter int D = 8;
`include "c2vec.svh"
    logic clk = 0;
    always #1 clk = !clk;
    logic start = 0;
    wire done, found;
    wire [8*MAXLEN-1:0] pw;
    wire [2:0] pwlen;
    wire [31:0] tried;
    logic [127:0] gm = '0;  // default alphabet a..z (set in initial below)
    crack2_engine #(.D(D), .MAXLEN(MAXLEN)) eng (
        .clk(clk), .start(start), .target(C2_TARGET), .salt(C2_SALT), .gmask(gm),
        .done(done), .found(found), .pw(pw), .pwlen(pwlen), .tried(tried));
    initial begin
        string got = "";
        for (int i = 97; i <= 122; i++) gm[i] = 1'b1;  // a..z
`ifdef C2DIGITS
        for (int i = 48; i <= 57; i++) gm[i] = 1'b1;    // also 0..9
`endif
        repeat (4) @(posedge clk);
        start <= 1; @(posedge clk); start <= 0; @(posedge clk);
        wait (done);
        for (int c = 0; c < int'(pwlen); c++) got = {got, string'(pw[8*(MAXLEN-1-c) +: 8])};
        $display("found=%b pwlen=%0d tried=%0d pw=%s", found, pwlen, tried, got);
        $display("%s", (found && pwlen == 3'(C2_PWLEN) && got == string'(C2_PW)) ? "TB PASS" : "TB FAIL");
        $finish;
    end
endmodule
