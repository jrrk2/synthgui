// byte_fifo — small synchronous byte FIFO.  Implemented as a PACKED shift
// register (no addressed `reg mem[]` array) so the SVS-native flow lowers it to
// flip-flops, not single-port LUTRAM (RAM32X1S), which the open-flow packer
// does not support.  The core pushes a byte and carries on; the FIFO drains to
// the slow UART transmitter in the background.  Output (dout) is the oldest
// entry (q[7:0]); writes append at the tail; reads shift the whole word down.
module byte_fifo #(parameter AW = 3) (      // 2^AW = 8 entries
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,                   // push din when !full
    input  wire [7:0] din,
    output wire       full,
    input  wire       rd,                   // pop when !empty
    output wire [7:0] dout,
    output wire       empty,
    output wire       nempty,               // ~empty (data available)
    output wire       nfull                 // ~full  (space available)
);
    localparam DEPTH = (1 << AW);           // 8
    reg  [DEPTH*8-1:0] q;                    // q[7:0] = oldest (output)
    reg  [AW:0]        cnt;                  // 0 .. DEPTH valid entries

    wire e  = (cnt == 0);
    wire f  = (cnt == DEPTH[AW:0]);
    wire dw = wr & ~f;                       // effective write
    wire dr = rd & ~e;                       // effective read

    assign empty  = e;
    assign full   = f;
    assign nempty = ~e;
    assign nfull  = ~f;
    assign dout   = q[7:0];

    // After an optional read, the word shifts down one byte and cnt drops by 1.
    wire [DEPTH*8-1:0] q_sh   = dr ? (q >> 8)      : q;
    wire [AW:0]        cnt_sh = dr ? (cnt - 1'b1)  : cnt;

    always @(posedge clk or posedge rst)
        if (rst) begin
            q <= {(DEPTH*8){1'b0}};
            cnt <= 0;
        end else begin
            q   <= q_sh;
            cnt <= cnt_sh;
            if (dw) begin
                q[(cnt_sh*8) +: 8] <= din;  // insert at the (post-read) tail
                cnt <= cnt_sh + 1'b1;
            end
        end
endmodule
