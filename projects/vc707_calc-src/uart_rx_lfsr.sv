// uart_rx_lfsr — 8N1 UART receiver with LFSR / shift-register timing only.
//
// The open flow mis-encodes CARRY4 arithmetic counters, which corrupts the
// stock apb_uart receiver (its baud/oversample/bit counters are arithmetic).
// This receiver uses ONLY shift-register LFSRs (shift + XOR, no carry) for its
// timing, so it maps to LUTs/FFs with zero CARRY4 — making the UART reliable
// "plumbing" so a deliberate CARRY4 adder can be the isolated device-under-test.
//
// 16x oversampling, sampled at bit centres.  rxtick = 16x-baud sample enable.
//   - bit-period counter: 5-bit maximal LFSR (taps 5,3), counts rxtick.
//     reseed each bit; HALF = state after 8 ticks, FULL = state after 16.
//   - data-bit counter: 4-bit maximal LFSR (taps 4,3), counts captured bits;
//     EIGHT = state after 8 bits.
//   - data: a plain shift register (LSB first), no counter-indexed write.
module uart_rx_lfsr (
    input  wire       clk,
    input  wire       rst,        // active-high
    input  wire       rxtick,     // 16x-baud sample enable (1-cycle pulse)
    input  wire       sin,        // synchronised serial input
    output reg  [7:0] dout,
    output reg        rxdone      // 1-cycle pulse when a byte has been received
);
    // 5-bit bit-period LFSR: fb = s[4]^s[2]; s <= {s[3:0], fb}.
    // Period must be exactly 16 rxticks/bit: a reseed costs one tick, and the
    // compare is pre-increment, so FULL = state@15 (16-tick period), HALF =
    // state@7 (~start-bit centre).  Using state@16 gives a 17-tick period that
    // drifts ~1 tick/bit and corrupts the high bits.
    localparam [4:0] SEED5 = 5'h1F, HALF5 = 5'h0D, FULL5 = 5'h14;
    reg  [4:0] bcnt;
    wire       bfb       = bcnt[4] ^ bcnt[2];
    wire [4:0] bcnt_next = {bcnt[3:0], bfb};
    wire       at_half   = (bcnt == HALF5);
    wire       at_full   = (bcnt == FULL5);

    // 4-bit data-bit LFSR: fb = s[3]^s[2]; s <= {s[2:0], fb}
    localparam [3:0] SEED4 = 4'hF, EIGHT4 = 4'h3;
    reg  [3:0] ncnt;
    wire       nfb       = ncnt[3] ^ ncnt[2];
    wire [3:0] ncnt_next = {ncnt[2:0], nfb};

    reg [7:0] dsr;                // data shift register (LSB first)

    localparam IDLE=2'd0, START=2'd1, DATA=2'd2, STOP=2'd3;
    reg [1:0] st;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st<=IDLE; bcnt<=SEED5; ncnt<=SEED4; dsr<=8'd0; dout<=8'd0; rxdone<=1'b0;
        end else begin
            rxdone <= 1'b0;
            case (st)
            IDLE: begin
                bcnt<=SEED5; ncnt<=SEED4;
                if (sin==1'b0) st<=START;          // start-bit leading edge
            end
            START: if (rxtick) begin
                if (at_half) begin                 // centre of the start bit
                    bcnt<=SEED5;                   // restart period count for bit0
                    st <= (sin==1'b0) ? DATA : IDLE; // confirm real start
                end else bcnt<=bcnt_next;
            end
            DATA: if (rxtick) begin
                if (at_full) begin                 // centre of a data bit
                    dsr  <= {sin, dsr[7:1]};       // shift in LSB-first
                    bcnt <= SEED5;
                    if (ncnt_next == EIGHT4) st<=STOP;  // 8th bit captured
                    else ncnt <= ncnt_next;
                end else bcnt<=bcnt_next;
            end
            STOP: if (rxtick) begin
                if (at_full) begin                 // centre of the stop bit
                    dout<=dsr; rxdone<=1'b1; st<=IDLE;
                end else bcnt<=bcnt_next;
            end
            endcase
        end
    end
endmodule
