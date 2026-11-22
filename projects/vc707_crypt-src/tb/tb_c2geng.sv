// crack2_glyph_engine on its own: build an alnum code table (ascending ASCII, as the top's
// scanner does), drive one (target, salt) from c2vec.svh, check the recovery.
module tb_c2geng;
    parameter int MAXLEN = 6;
    parameter int D = 8;
    parameter int NG = 128;
`include "c2vec.svh"
    logic clk = 0;
    always #1 clk = !clk;
    logic start = 0;
    wire done, found;
    wire [8*MAXLEN-1:0] pw;
    wire [2:0] pwlen;
    wire [31:0] tried;
    logic [7*NG-1:0] code = '0;
    logic [7:0] ngl = 0;
    crack2_glyph_engine #(.D(D), .MAXLEN(MAXLEN), .NG(NG)) eng (
        .clk(clk), .start(start), .target(C2_TARGET), .salt(C2_SALT),
        .code(code), .ngl(ngl),
        .done(done), .found(found), .pw(pw), .pwlen(pwlen), .tried(tried));
    initial begin
        string got = "";
        int n = 0;
        // alnum, ascending ASCII: 0-9, A-Z, a-z
        for (int ch = 0; ch < 128; ch++)
            if ((ch>=48&&ch<=57)||(ch>=65&&ch<=90)||(ch>=97&&ch<=122)) begin
                code[7*n +: 7] = 7'(ch); n++;
            end
        ngl = 8'(n);
        repeat (4) @(posedge clk);
        start <= 1; @(posedge clk); start <= 0; @(posedge clk);
        wait (done);
        for (int c = 0; c < int'(pwlen); c++) got = {got, string'(pw[8*(MAXLEN-1-c) +: 8])};
        $display("ngl=%0d found=%b pwlen=%0d tried=%0d pw=%s", ngl, found, pwlen, tried, got);
        $display("%s", (found && pwlen == 3'(C2_PWLEN) && got == string'(C2_PW)) ? "TB PASS" : "TB FAIL");
        $finish;
    end
endmodule
