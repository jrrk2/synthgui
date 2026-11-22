// Unit test: crypt_hw(C2_PW, C2_SALT) via the salt-aware DES should equal C2_TARGET.
// Isolates the DES + run-time salt from the search engine.
module tb_c2des;
`include "crack2_des.svh"
`include "crack2_salt.svh"
`include "c2vec.svh"
    initial begin
        logic [1:64] blk, lr;
        logic [1:56] cd;
        string pw;
        pw  = string'(C2_PW);
        blk = '0;
        for (int c = 0; c < pw.len(); c++) blk[8*c+1 +: 8] = {7'(pw[c]), 1'b0};
        cd = des_pc1(blk);
        lr = '0;
        for (int i = 0; i < 25; i++) lr = des16_s(lr, cd, C2_SALT);
        $display("hw=%016x target=%016x", des_fp(lr), C2_TARGET);
        $display("%s", des_fp(lr) == C2_TARGET ? "TB PASS" : "TB FAIL");
        $finish;
    end
endmodule
