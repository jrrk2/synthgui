// UNIX V7 crypt(3) engine: D passwords in flight round a ring of D registers, and
// all sixteen rounds of the salt's DES sit in one cloud between the ring's last
// register and its first.  Each pass round the ring is one encrypt, so a password
// is done after ITER passes and every cycle does one DES; the cloud is as deep as
// sixteen rounds, with D-1 of the ring's registers doing nothing but delay.
//
// That is the shape register retiming is for (Leiserson and Saxe's C-slow
// circuit): moved forward into the cloud, the ring's registers cut it into D
// pieces and the clock can go about D times faster, with nothing else changed.
// The RTL is written with them bunched, so whatever the routed design gains over
// the same RTL without retiming is the retimer's.
//
// The ring has no enable and no reset (the registers retiming moves must share
// both); a slot that is not in use carries v = 0.  start begins a batch of N
// passwords, password(n) as in gen_crypt.py; done rises when all N are hashed,
// with sum the sum mod 2^64 of their 64-bit hashes (FP's output, bit 1 the MSB)
// and first password(0)'s.
module crypt_engine #(
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int unsigned N = 1 << 20
) (
    input  logic        clk,
    input  logic        start,
    output logic        done,
    output logic [63:0] sum,
    output logic [63:0] first
);
`include "crypt_des.svh"

    localparam int NW = $clog2(N + 1);
    localparam logic [47:0] MIX = 48'h5A5AC3C3A5A5;

    // the ring
    logic [1:64] st [D];
    logic [1:56] cd [D];
    logic [4:0]  it [D];
    logic [D-1:0] v = '0, tag = '0;

    // control (enables and their own reset: not part of the ring)
    logic          running = 1'b0;
    logic [NW-1:0] n = '0, nfin = '0;
    logic          out_v = 1'b0, out_tag = 1'b0;
    logic [1:64]   out_h;

    // password(n): eight characters of ./0-9A-Za-z from the 48 bits of n ^ MIX
    function automatic logic [6:0] alpha(input logic [5:0] x);
        if (x < 6'd12) return 7'(x) + 7'd46;
        if (x < 6'd38) return 7'(x) + 7'd53;
        return 7'(x) + 7'd59;
    endfunction
    function automatic logic [1:56] key_of(input logic [NW-1:0] i);
        logic [47:0] w;
        logic [1:64] blk;
        w = 48'(i) ^ MIX;
        for (int c = 0; c < 8; c++) blk[8 * c + 1 +: 8] = {alpha(w[6 * c +: 6]), 1'b0};
        return des_pc1(blk);
    endfunction

    wire [1:64] nxt = des16(st[D-1], cd[D-1]);
    wire last = v[D-1] && it[D-1] == 5'(ITER - 1);
    wire load = (last || !v[D-1]) && running && n != NW'(N);

    always_ff @(posedge clk) begin
        st[0]  <= load ? 64'b0 : nxt;
        cd[0]  <= load ? key_of(n) : cd[D-1];
        it[0]  <= load ? 5'd0 : it[D-1] + 5'd1;
        v[0]   <= load || (v[D-1] && !last);
        tag[0] <= load ? n == '0 : tag[D-1];
        for (int i = 1; i < D; i++) begin
            st[i]  <= st[i-1];
            cd[i]  <= cd[i-1];
            it[i]  <= it[i-1];
            v[i]   <= v[i-1];
            tag[i] <= tag[i-1];
        end
        out_v   <= last;
        out_tag <= last && tag[D-1];
        out_h   <= nxt;
    end

    always_ff @(posedge clk) begin
        if (start) begin
            running <= 1'b1;
            n       <= '0;
            nfin    <= '0;
            sum     <= '0;
        end else begin
            if (load) n <= n + 1'b1;
            if (out_v) begin
                nfin <= nfin + 1'b1;
                sum  <= sum + des_fp(out_h);
            end
            if (out_tag) first <= des_fp(out_h);
            if (nfin == NW'(N)) running <= 1'b0;
        end
    end
    assign done = !running;
endmodule
