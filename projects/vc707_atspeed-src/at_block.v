// at_block: the at-speed path-delay test block (placeholder, NPATHS = 1).
//
// Launch domain clk_l, capture domain clk_c: two outputs of the same MMCM,
// nominally identical, the capture clock's phase swept from the BIOS (tmmcm).
// A 32-bit LFSR in clk_l supplies the launch bit; each path has a launch FF
// lq (clk_l, CE = run), a reference FF rq (clk_c, D = lq directly) and a
// capture FF cq (clk_c, D = lq through the path under test -- the same wire
// here; the real circuits route a path between them).  An error FF in clk_c
// flags rq != cq and a 16-bit counter per path counts the error cycles while
// run is set.  ld loads every counter into a shift chain in clk_l (path 0 at
// the output end), sh_en shifts it one bit per clk_l cycle towards sh_out,
// MSB first.
//
// Control (rst, run, ld, sh_en) is synchronous to clk_l and comes from the
// harness's own clk_l flip-flops; run and rst are resynchronised into clk_c
// here with two flip-flops.  Later versions with hundreds of paths replace
// this module by partial reconfiguration, so the harness depends on nothing
// but these seven ports.  Plain always blocks, no vendor primitives, no
// initial values: everything is set by rst.
module at_block (
    input  wire clk_l,
    input  wire clk_c,
    input  wire rst,
    input  wire run,
    input  wire ld,
    input  wire sh_en,
    output wire sh_out
);
    localparam NPATHS = 1;

    // Launch bit: a 32-bit maximal-length LFSR (x^32 + x^22 + x^2 + x + 1)
    reg  [31:0] lfsr;
    wire        fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];
    always @(posedge clk_l)
        if (rst)      lfsr <= 32'hACE1_2357;
        else if (run) lfsr <= {lfsr[30:0], fb};
    wire b = lfsr[0];

    // run and rst into the capture domain
    reg run_c0, run_c, rst_c0, rst_c;
    always @(posedge clk_c) begin
        run_c0 <= run;  run_c <= run_c0;
        rst_c0 <= rst;  rst_c <= rst_c0;
    end

    // Path 0: launch, reference, capture, error, error counter
    reg        lq;
    reg        rq, cq, e;
    reg [15:0] cnt0;
    always @(posedge clk_l)
        if (run) lq <= b;
    always @(posedge clk_c) begin
        rq <= lq;
        cq <= lq;          // the path under test goes here
        e  <= rq ^ cq;
        if (rst_c)              cnt0 <= 16'd0;
        else if (run_c && e)    cnt0 <= cnt0 + 16'd1;
    end

    // Results shift chain, clk_l: path 0 in the top 16 bits, MSB at sh_out
    reg [16*NPATHS-1:0] sh;
    always @(posedge clk_l)
        if (ld)         sh <= {cnt0};
        else if (sh_en) sh <= {sh[16*NPATHS-2:0], 1'b0};
    assign sh_out = sh[16*NPATHS-1];
endmodule
