// Generic LFSR (PRBS) clock divider: emits a 1-cycle `tick` every N `ce` pulses
// using a left-shift Fibonacci LFSR (shift + XOR, NO carry chain), so it is
// immune to the open-flow CARRY4 arithmetic-counter encoding bug.  Replaces the
// arithmetic uart_baudgen / slib_clock_div so EVERY divider in the UART is
// carry-free (the ADD4 adder is then the only intentional CARRY4 = the DUT).
//
// Parameters for divide ratio N (precompute in Python):
//   TAPS     = feedback bit mask (maximal-length taps), fb = XOR of tapped bits
//   SEED     = nonzero start state
//   TERMINAL = LFSR state after (N-1) steps from SEED  -> tick every N ce's
module lfsr_div #(
    parameter int     W        = 7,
    parameter [W-1:0] TAPS     = 7'h60,
    parameter [W-1:0] SEED     = 7'h7F,
    parameter [W-1:0] TERMINAL = 7'h77
) (
    input  wire clk,
    input  wire rst,        // active-high
    input  wire ce,
    output wire tick
);
    reg  [W-1:0] s;
    wire         fb = ^(s & TAPS);
    wire         at = (s == TERMINAL);
    always @(posedge clk or posedge rst)
        if (rst)      s <= SEED;
        else if (ce)  s <= at ? SEED : {s[W-2:0], fb};
    assign tick = ce & at;
endmodule
