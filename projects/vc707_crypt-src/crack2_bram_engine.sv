// STRETCH GOAL, DELIVERED: the configurable-alphabet engine with its glyph table held in a RAM
// (the remap library maps an inferred memory to RAM) instead of an 896-bit flop vector read by
// wide muxes.  That flop-vector form is crack2_glyph_engine, kept as a router-divergence demo;
// this version routes cleanly and is faster than the fixed-alphabet build:
//   remap library:   codemem -> 168x RAM64X1D (distributed RAM), not muxes
//   nextpnr:         converges, overused -> 0 (the glyph version diverged to >11000)
//   OpenSTA:         122.20 MHz, setup slack +0.159 ns MET
//   on the board:    recovers x9 / Ab3 / cat1 / Zz9 over an alnum alphabet set by '%' command
//
// The table is an UNPACKED array `codemem` (so the mapper's remap library recognises it as a
// memory), written once by an internal scanner and read as index->ASCII.  On `start` the engine
// first walks the 128 mask bits, appending each set one to codemem[0..ngl-1] (the build phase,
// <=128 cycles, gated by `built`), then sweeps indices exactly like crack2_glyph_engine.
//
// Reads here are asynchronous, so the mapper realises codemem as distributed RAM (LUTRAM),
// replicated per read port -- combinational, so the ring/control are unchanged from the glyph
// engine.  For true block RAM (RAMB36E1) the reads would need registering (one pipeline stage).
module crack2_bram_engine #(
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int MAXLEN = 6,
    parameter int NG = 128
) (
    input  logic                  clk,
    input  logic                  start,
    input  logic [63:0]           target,
    input  logic [11:0]           salt,
    input  logic [127:0]          gmask,    // the alphabet, scanned into codemem on start
    output logic                  done,
    output logic                  found,
    output logic [8*MAXLEN-1:0]   pw,
    output logic [2:0]            pwlen,
    output logic [31:0]           tried
);
`include "crack2_des.svh"

    localparam int DW = 7 * MAXLEN;

    `include "crack2_salt.svh"

    // the glyph table: index -> 7-bit ASCII code, as an unpacked array so the remap library
    // maps it to RAM rather than to muxes over a flop vector.
    (* ram_style = "distributed" *) logic [6:0] codemem [NG];
    logic [7:0] ngl = 8'd0;

    // index -> ASCII.  Asynchronous read (distributed RAM).  For block RAM, register this.
    function automatic logic [6:0] code_of(input logic [6:0] idx);
        return codemem[idx];
    endfunction

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
    logic [DW-1:0]  pk [D];
    logic [2:0]     pl [D];
    logic [11:0]    sr [D];
    logic [63:0]    tr [D];
    logic [D-1:0]   v = '0;

    logic          running = 1'b0, swept = 1'b0, built = 1'b0, building = 1'b0;
    logic [7:0]    bscan = '0, nb = '0;
    logic [DW-1:0] cur = '0;
    logic [2:0]    plen = 3'd1;

    wire [6:0] idxmax = 7'(ngl - 8'd1);

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
    wire        load = built && (last || !v[D-1]) && running && !swept && !found;
    wire        hit  = last && des_fp(nxt) == tr[D-1];

    always_ff @(posedge clk) begin
        // ring shift (only meaningful once built; during build v stays 0 so nothing completes)
        st[0] <= load ? 64'b0 : nxt;
        cd[0] <= load ? loadkey : cd[D-1];
        it[0] <= load ? 5'd0 : it[D-1] + 5'd1;
        pk[0] <= load ? cur : pk[D-1];
        pl[0] <= load ? plen : pl[D-1];
        sr[0] <= load ? salt : sr[D-1];
        tr[0] <= load ? target : tr[D-1];
        for (int i = 1; i < D; i++) begin
            st[i] <= st[i-1]; cd[i] <= cd[i-1]; it[i] <= it[i-1]; pk[i] <= pk[i-1];
            pl[i] <= pl[i-1]; sr[i] <= sr[i-1]; tr[i] <= tr[i-1];
        end

        if (start) begin
            running  <= 1'b1;
            found    <= 1'b0;
            swept    <= 1'b0;
            tried    <= '0;
            cur      <= '0;
            plen     <= 3'd1;
            v        <= '0;
            building <= 1'b1;        // first scan the mask into codemem
            built    <= 1'b0;
            bscan    <= '0;
            nb       <= '0;
        end else if (building) begin
            if (gmask[bscan]) begin
                codemem[nb] <= 7'(bscan);
                nb          <= nb + 8'd1;
            end
            if (bscan == 8'(NG - 1)) begin
                building <= 1'b0;
                built    <= 1'b1;
                ngl      <= nb + (gmask[bscan] ? 8'd1 : 8'd0);
            end
            bscan <= bscan + 8'd1;
        end else begin
            v[0] <= load || (v[D-1] && !last);
            for (int i = 1; i < D; i++) v[i] <= v[i-1];
            if (running && built) begin
                if (load) begin
                    tried <= tried + 1'b1;
                    if (lenwrap) begin
                        if (int'(plen) == MAXLEN) swept <= 1'b1;
                        else begin plen <= plen + 1'b1; cur <= '0; end
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
