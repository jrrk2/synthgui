// Password search with a run-time salt and variable length, over the fixed lowercase alphabet
// a..z.  Given one crypt line's 12-bit salt and 64-bit hash, it sweeps every string of 1..MAXLEN
// lowercase letters and stops at the one whose crypt hash matches.  This is the shipped engine:
// the alphabet is a compile-time constant, so the odometer is a plain base-26 counter that closes
// timing at 100 MHz.  (A configurable-alphabet variant, crack2_glyph_engine, is kept as a stretch
// goal: it takes a run-time 128-bit glyph mask but its odometer does not meet 100 MHz yet.)
//
// The ring is crypt_engine's (D candidates in flight, ITER passes each); it carries each
// candidate's letters and length so the match can be reported.
//
// The salt is crypt's: twelve bits that, per set bit k, swap E-table entries k and k+24.
// Swapping two E entries is the same as swapping the two expanded bits they produce, so the
// unsalted E (crack2_des.svh) is expanded and then bits k, k+24 are swapped for salt bit k
// (exp_salt).  The salt is one value for the whole search, so these are 24 two-way muxes in
// the round function, not per candidate.
module crack2_engine #(
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int MAXLEN = 6
) (
    input  logic                  clk,
    input  logic                  start,    // pulse: search for (target, salt)
    input  logic [63:0]           target,
    input  logic [11:0]           salt,
    output logic                  done,     // found, or every string tried
    output logic                  found,
    output logic [8*MAXLEN-1:0]   pw,        // recovered letters, leftmost in the MSB, 0-padded
    output logic [2:0]            pwlen,
    output logic [31:0]           tried
);
`include "crack2_des.svh"

    localparam int DW = 7 * MAXLEN;    // each digit is a 7-bit ASCII letter code
    localparam logic [6:0] LO = 7'd97; // 'a'
    localparam logic [6:0] HI = 7'd122;// 'z'

    `include "crack2_salt.svh"

    // the DES key of a candidate: letter c for c < plen, else a zero character
    function automatic logic [1:56] key_of(input logic [DW-1:0] d, input logic [2:0] pl);
        logic [1:64] blk;
        blk = '0;
        for (int c = 0; c < MAXLEN; c++)
            if (c < int'(pl)) blk[8*c+1 +: 8] = {d[7*c +: 7], 1'b0};
        return des_pc1(blk);
    endfunction

    // the ring (st/cd/it/pk/pl/sr/tr assigned every cycle, no enable or reset: retiming moves
    // st/cd forward into the DES cloud).  The candidate's letters (pk) travel with it so the
    // identity and the key can never drift apart.
    logic [1:64]    st [D];
    logic [1:56]    cd [D];
    logic [4:0]     it [D];
    logic [DW-1:0]  pk [D];
    logic [2:0]     pl [D];
    logic [11:0]    sr [D];   // the salt, carried in the ring (same for every slot in a search)
    logic [63:0]    tr [D];   // the target hash, likewise
    logic [D-1:0]   v = '0;

    // control (its own reset)
    logic          running = 1'b0, swept = 1'b0;
    logic [DW-1:0] cur = '0;
    logic [2:0]    plen = 3'd1;

    localparam logic [DW-1:0] CURLO = {MAXLEN{LO}};  // all positions at 'a'

    // the next candidate: a base-26 odometer on the plen active letters, each a..z; lenwrap when
    // every active letter is already 'z'.  Only the one-bit carry ripples across digits.
    logic [DW-1:0] curn;
    logic          lenwrap;
    always_comb begin
        logic carry;
        curn  = cur;
        carry = 1'b1;
        for (int c = MAXLEN - 1; c >= 0; c--)
            if (c < int'(plen)) begin
                if (carry) curn[7*c +: 7] = (cur[7*c +: 7] == HI) ? LO : cur[7*c +: 7] + 7'd1;
                carry = carry & (cur[7*c +: 7] == HI);
            end
        lenwrap = carry;
    end

    wire [1:56] loadkey = key_of(cur, plen);  // this load's key, from the live counter
    wire [1:64] nxt     = des16_s(st[D-1], cd[D-1], sr[D-1]);
    wire        last = v[D-1] && it[D-1] == 5'(ITER - 1);
    wire        load = (last || !v[D-1]) && running && !swept && !found;
    wire        hit  = last && des_fp(nxt) == tr[D-1];

    // One block: the ring (st/cd/it/pk/pl shift every cycle, no enable or reset, so retiming can
    // move st/cd forward into the DES cloud) and the control, so cd and pk load from the same
    // `cur` with no cross-block ambiguity.  `v` is cleared on start: the ring must empty between
    // searches (the service runs one per line).
    always_ff @(posedge clk) begin
        st[0] <= load ? 64'b0 : nxt;
        cd[0] <= load ? loadkey : cd[D-1];
        it[0] <= load ? 5'd0 : it[D-1] + 5'd1;
        pk[0] <= load ? cur : pk[D-1];
        pl[0] <= load ? plen : pl[D-1];
        sr[0] <= load ? salt : sr[D-1];      // salt/target enter the no-enable ring at load, so the
        tr[0] <= load ? target : tr[D-1];    // DES cloud reads ring regs (retimable), not enabled ones
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
            cur     <= CURLO;
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
                            cur  <= CURLO;
                        end
                    end else cur <= curn;
                end
                if (hit && !found) begin
                    found <= 1'b1;
                    pwlen <= pl[D-1];
                    for (int c = 0; c < MAXLEN; c++)
                        pw[8*(MAXLEN-1-c) +: 8] <=
                            (c < int'(pl[D-1])) ? {1'b0, pk[D-1][7*c +: 7]} : 8'd0;
                end
                if (found || (swept && v == '0)) running <= 1'b0;
            end
        end
    end
    assign done = !running;
endmodule
