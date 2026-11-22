// STRETCH GOAL (kept as a router-divergence demonstration -- see crack2_glyph_divergence.log).
//
// Password search over a run-time-configurable alphabet.  The alphabet is given not as a
// 128-bit mask but as a compact table: `code[j]` is the ASCII code of the j-th glyph
// (j = 0 .. ngl-1), built once by the top from the mask.  Each odometer digit holds an INDEX
// 0..ngl-1, so incrementing a digit is "idx+1, wrap to 0 at ngl" and lenwrap is "every active
// index == ngl-1" -- small integer arithmetic, no 128-bit priority encoder on the per-cycle
// path.  The ASCII code only enters at two slow points: forming the DES key of a loaded
// candidate (key_of, feeding the retimable DES cloud), and reporting a hit.
//
// This moves the glyph lookup off the timing-critical path -- but as written the table is an
// 896-bit flop vector (code) read by MAXLEN parallel 128:1 part-select muxes, which is a huge,
// high-fanout combinational cloud.  nextpnr's router cannot route it: congestion descends to a
// minimum then climbs away (divergence).  It is functionally correct in simulation (the engine
// recovers A/7/a1/z0/Zz), so it is kept as a clean demonstration of that non-convergence.  The
// real fix is to hold `code` in a true RAM (unpacked array -> LUTRAM with replicated read
// ports) instead of a flop vector read by muxes.
//
// Ring, salt and retiming are identical to crack2_engine; only the candidate generator differs.
module crack2_glyph_engine #(
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int MAXLEN = 6,
    parameter int NG = 128           // table depth (max glyphs); indices are 7-bit
) (
    input  logic                  clk,
    input  logic                  start,
    input  logic [63:0]           target,
    input  logic [11:0]           salt,
    input  logic [7*NG-1:0]       code,     // glyph j -> 7-bit ASCII (code[7*j +: 7])
    input  logic [7:0]            ngl,      // number of glyphs in the alphabet (1..NG)
    output logic                  done,
    output logic                  found,
    output logic [8*MAXLEN-1:0]   pw,
    output logic [2:0]            pwlen,
    output logic [31:0]           tried
);
`include "crack2_des.svh"

    localparam int DW = 7 * MAXLEN;   // each digit is a 7-bit glyph INDEX

    `include "crack2_salt.svh"

    wire [6:0] idxmax = 7'(ngl - 8'd1);   // highest index in the alphabet

    // index -> ASCII (the table read)
    function automatic logic [6:0] code_of(input logic [6:0] idx);
        return code[7*idx +: 7];
    endfunction

    // the DES key of a candidate: glyph code[idx] for c < plen, else a zero character
    function automatic logic [1:56] key_of(input logic [DW-1:0] d, input logic [2:0] pl);
        logic [1:64] blk;
        blk = '0;
        for (int c = 0; c < MAXLEN; c++)
            if (c < int'(pl)) blk[8*c+1 +: 8] = {code_of(d[7*c +: 7]), 1'b0};
        return des_pc1(blk);
    endfunction

    // the ring (no enable or reset: retiming moves st/cd into the DES cloud)
    logic [1:64]    st [D];
    logic [1:56]    cd [D];
    logic [4:0]     it [D];
    logic [DW-1:0]  pk [D];    // candidate indices
    logic [2:0]     pl [D];
    logic [11:0]    sr [D];
    logic [63:0]    tr [D];
    logic [D-1:0]   v = '0;

    logic          running = 1'b0, swept = 1'b0;
    logic [DW-1:0] cur = '0;    // odometer of indices; 0 = first glyph
    logic [2:0]    plen = 3'd1;

    // the next candidate: an odometer on indices, each 0..idxmax; lenwrap when every active
    // index is already idxmax.  Only the one-bit carry ripples.
    logic [DW-1:0] curn;
    logic          lenwrap;
    always_comb begin
        logic carry;
        curn  = cur;
        carry = 1'b1;
        for (int c = MAXLEN - 1; c >= 0; c--)
            if (c < int'(plen)) begin
                if (carry) curn[7*c +: 7] = (cur[7*c +: 7] == idxmax) ? 7'd0
                                                                       : cur[7*c +: 7] + 7'd1;
                carry = carry & (cur[7*c +: 7] == idxmax);
            end
        lenwrap = carry;
    end

    wire [1:56] loadkey = key_of(cur, plen);
    wire [1:64] nxt     = des16_s(st[D-1], cd[D-1], sr[D-1]);
    wire        last = v[D-1] && it[D-1] == 5'(ITER - 1);
    wire        load = (last || !v[D-1]) && running && !swept && !found;
    wire        hit  = last && des_fp(nxt) == tr[D-1];

    always_ff @(posedge clk) begin
        st[0] <= load ? 64'b0 : nxt;
        cd[0] <= load ? loadkey : cd[D-1];
        it[0] <= load ? 5'd0 : it[D-1] + 5'd1;
        pk[0] <= load ? cur : pk[D-1];
        pl[0] <= load ? plen : pl[D-1];
        sr[0] <= load ? salt : sr[D-1];
        tr[0] <= load ? target : tr[D-1];
        for (int i = 1; i < D; i++) begin
            st[i] <= st[i-1];
            cd[i] <= cd[i-1];
            it[i] <= it[i-1];
            pk[i] <= pk[i-1];
            pl[i] <= pl[i-1];
            sr[i] <= sr[i-1];
            tr[i] <= tr[i-1];
        end
        if (start) begin
            running <= 1'b1;
            found   <= 1'b0;
            swept   <= 1'b0;
            tried   <= '0;
            cur     <= '0;
            plen    <= 3'd1;
            v       <= '0;
        end else begin
            v[0] <= load || (v[D-1] && !last);
            for (int i = 1; i < D; i++) v[i] <= v[i-1];
            if (running) begin
                if (load) begin
                    tried <= tried + 1'b1;
                    if (lenwrap) begin
                        if (int'(plen) == MAXLEN) swept <= 1'b1;
                        else begin
                            plen <= plen + 1'b1;
                            cur  <= '0;
                        end
                    end else cur <= curn;
                end
                if (hit && !found) begin
                    found <= 1'b1;
                    pwlen <= pl[D-1];
                    for (int c = 0; c < MAXLEN; c++)
                        pw[8*(MAXLEN-1-c) +: 8] <=
                            (c < int'(pl[D-1])) ? {1'b0, code_of(pk[D-1][7*c +: 7])} : 8'd0;
                end
                if (found || (swept && v == '0)) running <= 1'b0;
            end
        end
    end
    assign done = !running;
endmodule
