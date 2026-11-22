// A password search on the same crypt engine: instead of a counter's passwords, it
// sweeps every lowercase string of PWLEN letters (26^PWLEN of them), hashes each with
// the salt built into crypt_des.svh, and stops at the one whose hash is TARGET.  This
// is Morris and Thompson's point in "Password Security: A Case History": a short
// monocase password has so few possibilities that its hashed line in /etc/passwd can
// be turned back into the password by trying them all.  26^6 is about 3.1e8, which at
// one hash a cycle (the retimed engine, ~100 MHz) is a few seconds.
//
// The ring is crypt_engine's, D candidates in flight, ITER passes each.  It carries the
// candidate's letters (pk) alongside the DES state so the matching one can be reported;
// cd is the key and cannot be read back, pk is the plaintext the search is recovering.
module crack_engine #(
    parameter int D = 8,
    parameter int ITER = 25,
    parameter int PWLEN = 6,
    parameter logic [63:0] TARGET = '0
) (
    input  logic                  clk,
    input  logic                  start,
    output logic                  done,     // search over (found, or every string tried)
    output logic                  found,
    output logic [8*PWLEN-1:0]    pw,        // the recovered letters, leftmost in the MSB
    output logic [31:0]           tried
);
`include "crypt_des.svh"

    localparam int DW = 5 * PWLEN;  // the candidate as PWLEN base-26 digits, 5 bits each

    // the ring (st/cd/it/pk assigned every cycle, no enable or reset: retiming moves them)
    logic [1:64]    st [D];
    logic [1:56]    cd [D];
    logic [4:0]     it [D];
    logic [DW-1:0]  pk [D];
    logic [D-1:0]   v = '0;

    // control (has its own reset, not part of the ring)
    logic          running = 1'b0;
    logic [DW-1:0] cur = '0;   // the next candidate to load, digit c (0 = leftmost) at [5*c +: 5]
    logic          swept = 1'b0;  // every candidate has been loaded

    // the DES key of a candidate: letter c is 'a' + digit c, seven bits MSB first, then
    // zero characters to eight, as crypt builds the key from the password.
    function automatic logic [1:56] key_of(input logic [DW-1:0] d);
        logic [1:64] blk;
        blk = '0;
        for (int c = 0; c < PWLEN; c++)
            blk[8*c+1 +: 8] = {7'd97 + 7'(d[5*c +: 5]), 1'b0};
        return des_pc1(blk);
    endfunction

    wire [1:64] nxt  = des16(st[D-1], cd[D-1]);
    wire        last = v[D-1] && it[D-1] == 5'(ITER - 1);
    wire        load = (last || !v[D-1]) && running && !swept && !found;
    wire        hit  = last && des_fp(nxt) == TARGET;

    // the next candidate (base-26, rippling from the rightmost letter); cwrap past "zz..z"
    logic [DW-1:0] curn;
    logic          cwrap;
    always_comb begin
        logic carry;
        curn  = cur;
        carry = 1'b1;
        for (int c = PWLEN - 1; c >= 0; c--)
            if (carry) begin
                if (cur[5*c +: 5] == 5'd25) curn[5*c +: 5] = 5'd0;
                else begin
                    curn[5*c +: 5] = cur[5*c +: 5] + 5'd1;
                    carry = 1'b0;
                end
            end
        cwrap = carry;
    end

    always_ff @(posedge clk) begin
        st[0] <= load ? 64'b0 : nxt;
        cd[0] <= load ? key_of(cur) : cd[D-1];
        it[0] <= load ? 5'd0 : it[D-1] + 5'd1;
        pk[0] <= load ? cur : pk[D-1];
        v[0]  <= load || (v[D-1] && !last);
        for (int i = 1; i < D; i++) begin
            st[i] <= st[i-1];
            cd[i] <= cd[i-1];
            it[i] <= it[i-1];
            pk[i] <= pk[i-1];
            v[i]  <= v[i-1];
        end
    end

    always_ff @(posedge clk) begin
        if (start) begin
            running <= 1'b1;
            found   <= 1'b0;
            swept   <= 1'b0;
            cur     <= '0;
            tried   <= '0;
        end else if (running) begin
            if (load) begin
                cur   <= curn;
                tried <= tried + 1'b1;
                if (cwrap) swept <= 1'b1;
            end
            if (hit && !found) begin
                found <= 1'b1;
                for (int c = 0; c < PWLEN; c++)
                    pw[8*(PWLEN-1-c) +: 8] <= 8'd97 + 8'(pk[D-1][5*c +: 5]);
            end
            // over when found, or when the sweep is loaded and the pipe has drained
            if (found || (swept && v == '0)) running <= 1'b0;
        end
    end
    assign done = !running;
endmodule
