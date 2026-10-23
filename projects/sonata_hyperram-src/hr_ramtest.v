// RAM test for the Sonata board's W956D8MBYA HyperRAM (8 MB) through LiteX's HyperRAM core.
//
// After reset: writes CR0 (the device powers up in fixed 7-clock latency; the core is built for
// variable, 4 clocks, and the two must agree, see sonata-lib/gen_hyperram.py), reads it back and
// the ID registers, then loops forever over four phases of the whole RAM:
//
//     0 write a pseudo-random sequence   1 read it back and compare
//     2 write its complement             3 read it back and compare
//
// The sequence is xorshift32, stepped once per word: a word read from or written to the wrong
// address, or with bits crossed, cannot match by accident, and the complement pass moves every
// data line both ways.  Words go in bursts of BURST: the core keeps a chip-select open for as
// long as the addresses run on, and the device allows 4 us, so the master ends each burst.
//
// Everything is in one clock, `clk`: the HyperRAM clock is clk/4 (80 MHz -> 20 MHz).
// A hang -- no acknowledge for TIMEOUT cycles -- restarts the controller and counts in `touts`.
module hr_ramtest #(
    parameter integer WORDS_LOG2 = 21,        // 2M words of 32 bits = 8 MB
    parameter integer BURST = 16,             // words per chip-select
    parameter integer RST_CYCLES = 200,       // RESET# low >= 200 ns
    parameter integer POR_CYCLES = 20000,     // then 150 us before the first access (250 us at 80 MHz)
    parameter integer TIMEOUT = 20000,
    parameter [31:0] SEED = 32'h2545F491
) (
    input wire clk,
    input wire rst,
    input wire [15:0] cr0_wr,                 // written to CR0: latency, fixed or variable, burst
    output wire hr_rst_n,
    output wire hr_cs_n,
    output wire hr_ck_p,
    output wire hr_ck_n,
    output wire [7:0] hr_dq_o,
    input wire [7:0] hr_dq_i,
    output wire hr_dq_oe,
    output wire hr_rwds_o,
    input wire hr_rwds_i,
    output wire hr_rwds_oe,

    output reg [15:0] id0 = 16'h0,
    output reg [15:0] id1 = 16'h0,
    output reg [15:0] cr0 = 16'h0,        // CR0 read back after writing it
    output reg [15:0] passes = 16'h0,     // completed four-phase loops
    output reg [1:0] phase = 2'd0,
    output reg [WORDS_LOG2-1:0] idx = 0,  // word being tested
    output reg [31:0] errs = 32'h0,       // words that read back wrong
    output reg [31:0] first_adr = 32'h0,  // byte address, expected and read value of the first
    output reg [31:0] first_exp = 32'h0,
    output reg [31:0] first_got = 32'h0,
    output reg [31:0] xors = 32'h0,       // every bit position that was ever wrong
    output reg [15:0] touts = 16'h0,
    output reg [31:0] pcyc = 32'h0,       // clock cycles the last phase took
    output reg running = 1'b0,            // past the register setup, testing
    output reg looped = 1'b0              // a whole four-phase loop has completed
);
    // ---- the controller
    reg hr_reset = 1'b0;
    reg [3:0] restart = 4'd0;
    wire core_rst = rst | (restart != 4'd0);

    reg reg_stb = 1'b0, reg_we = 1'b0;
    reg [2:0] reg_adr = 3'd0;
    reg [15:0] reg_dat_w = 16'h0;
    wire reg_ack;
    wire [15:0] reg_dat_r;

    reg wb_stb = 1'b0, wb_we = 1'b0;
    reg [2:0] wb_cti = 3'b000;
    reg [31:0] wb_dat_w = 32'h0;
    wire wb_ack;
    wire [31:0] wb_dat_r;

    litex_hyperram core (
        .sys_clk(clk), .sys_rst(core_rst),
        .hr_rst_n(hr_rst_n), .hr_cs_n(hr_cs_n), .hr_ck_p(hr_ck_p), .hr_ck_n(hr_ck_n),
        .hr_dq_o(hr_dq_o), .hr_dq_i(hr_dq_i), .hr_dq_oe(hr_dq_oe),
        .hr_rwds_o(hr_rwds_o), .hr_rwds_i(hr_rwds_i), .hr_rwds_oe(hr_rwds_oe),
        .hr_reset(hr_reset),
        .reg_adr(reg_adr), .reg_dat_w(reg_dat_w), .reg_dat_r(reg_dat_r),
        .reg_stb(reg_stb), .reg_ack(reg_ack), .reg_we(reg_we),
        .wb_adr({{(30 - WORDS_LOG2){1'b0}}, idx}), .wb_dat_w(wb_dat_w), .wb_dat_r(wb_dat_r),
        .wb_sel(4'hF), .wb_cyc(wb_stb), .wb_stb(wb_stb), .wb_ack(wb_ack),
        .wb_we(wb_we), .wb_cti(wb_cti)
    );

    // ---- the pattern: xorshift32, one step per word
    reg [31:0] s = SEED;
    wire [31:0] s1 = s ^ (s << 13);
    wire [31:0] s2 = s1 ^ (s1 >> 17);
    wire [31:0] s_next = s2 ^ (s2 << 5);
    wire inv = phase[1];
    wire [31:0] word = inv ? ~s : s;

    // ---- sequencer
    localparam [3:0] S_RESET = 4'd0, S_POR = 4'd1, S_REG = 4'd2, S_GAP = 4'd3, S_BEAT = 4'd4,
                     S_NEXT = 4'd5;
    reg [3:0] st = S_RESET;
    reg [31:0] cnt = 32'd0;      // delay counter
    reg [31:0] wd = 32'd0;       // cycles spent waiting for an acknowledge
    reg [2:0] ri = 3'd0;         // register step
    reg [7:0] beat = 8'd0;       // word within the burst
    reg [31:0] pc = 32'd0;       // cycles in this phase
    wire last_word = &idx;
    wire write = !phase[0];
    wire [31:0] got = wb_dat_r;

    // ---- the checker, three stages: a 32-bit compare, the zero test, then the counters
    reg c1_v = 1'b0, c2_v = 1'b0, c3_v = 1'b0;
    reg [31:0] c1_got, c1_exp, c2_diff, c2_got, c2_exp, c3_diff, c3_got, c3_exp;
    reg [WORDS_LOG2-1:0] c1_idx, c2_idx, c3_idx;
    always @(posedge clk) begin
        c1_v <= wb_stb && wb_ack && !write;
        c1_got <= got;
        c1_exp <= word;
        c1_idx <= idx;
        c2_v <= c1_v;
        c2_diff <= c1_got ^ c1_exp;
        c2_got <= c1_got;
        c2_exp <= c1_exp;
        c2_idx <= c1_idx;
        c3_v <= c2_v && (c2_diff != 32'h0);
        c3_diff <= c2_diff;
        c3_got <= c2_got;
        c3_exp <= c2_exp;
        c3_idx <= c2_idx;
    end

    always @(posedge clk) begin
        if (restart != 4'd0) restart <= restart - 4'd1;
        if (rst) begin
            st <= S_RESET;
            cnt <= 32'd0;
            hr_reset <= 1'b0;
            reg_stb <= 1'b0;
            wb_stb <= 1'b0;
            running <= 1'b0;
            looped <= 1'b0;
            passes <= 16'h0;
            phase <= 2'd0;
            idx <= 0;
            errs <= 32'h0;
            xors <= 32'h0;
            touts <= 16'h0;
            first_adr <= 32'h0;
            first_exp <= 32'h0;
            first_got <= 32'h0;
            pcyc <= 32'h0;
            ri <= 3'd0;
        end else begin
            if (c3_v) begin
                errs <= errs + 32'd1;
                xors <= xors | c3_diff;
                if (errs == 32'd0) begin
                    first_adr <= {{(30 - WORDS_LOG2){1'b0}}, c3_idx, 2'b00};
                    first_exp <= c3_exp;
                    first_got <= c3_got;
                end
            end
            wd <= (!(reg_stb || wb_stb) || reg_ack || wb_ack) ? 32'd0 : wd + 32'd1;
            if (wd == TIMEOUT) begin  // hung: start again from the reset, count it
                touts <= touts + 16'd1;
                restart <= 4'd8;
                st <= S_RESET;
                cnt <= 32'd0;
                reg_stb <= 1'b0;
                wb_stb <= 1'b0;
                running <= 1'b0;
                ri <= 3'd0;
                phase <= 2'd0;
                idx <= 0;
                wd <= 32'd0;
            end else case (st)
                S_RESET: begin
                    hr_reset <= 1'b1;
                    cnt <= cnt + 32'd1;
                    if (cnt == RST_CYCLES) begin
                        hr_reset <= 1'b0;
                        cnt <= 32'd0;
                        st <= S_POR;
                    end
                end
                S_POR: begin
                    cnt <= cnt + 32'd1;
                    if (cnt == POR_CYCLES) begin
                        cnt <= 32'd0;
                        st <= S_REG;
                    end
                end
                S_REG: begin
                    // 0 write CR0 (a register write has no latency to get wrong), 1 read it back,
                    // 2 ID0, 3 ID1
                    if (!reg_stb) begin
                        reg_stb <= 1'b1;
                        reg_we <= (ri == 3'd0);
                        reg_adr <= (ri == 3'd2) ? 3'd0 : (ri == 3'd3) ? 3'd1 : 3'd2;
                        reg_dat_w <= cr0_wr;
                    end else if (reg_ack) begin
                        reg_stb <= 1'b0;
                        case (ri)
                            3'd1: cr0 <= reg_dat_r;
                            3'd2: id0 <= reg_dat_r;
                            3'd3: id1 <= reg_dat_r;
                            default: ;
                        endcase
                        if (ri == 3'd3) begin
                            running <= 1'b1;
                            ri <= 3'd0;
                            phase <= 2'd0;
                            idx <= 0;
                            s <= SEED;
                            beat <= 8'd0;
                            pc <= 32'd1;
                            st <= S_GAP;
                            cnt <= 32'd0;
                        end else ri <= ri + 3'd1;
                    end
                end
                S_GAP: begin
                    // The core ends a burst when no request follows, but takes the next one as
                    // a continuation (and keeps the chip select open) if it arrives, with the
                    // next address, before it has finished sending the last word.  So wait for
                    // the chip select to go high.
                    pc <= pc + 32'd1;
                    cnt <= hr_cs_n ? cnt + 32'd1 : 32'd0;
                    if (cnt == 32'd3) begin
                        cnt <= 32'd0;
                        beat <= 8'd0;
                        wb_stb <= 1'b1;
                        wb_we <= write;
                        wb_dat_w <= word;
                        wb_cti <= 3'b010;
                        st <= S_BEAT;
                    end
                end
                S_BEAT: begin
                    pc <= pc + 32'd1;
                    if (wb_ack) begin
                        s <= s_next;
                        if (last_word) begin
                            // phase done
                            wb_stb <= 1'b0;
                            pcyc <= pc;
                            idx <= 0;
                            s <= SEED;
                            phase <= phase + 2'd1;
                            if (phase == 2'd3) begin
                                passes <= passes + 16'd1;
                                looped <= 1'b1;
                            end
                            pc <= 32'd1;
                            st <= S_GAP;
                        end else begin
                            idx <= idx + 1'b1;
                            beat <= beat + 8'd1;
                            if (beat == BURST - 1) begin
                                wb_stb <= 1'b0;
                                st <= S_GAP;
                            end else begin
                                // the next word of the burst
                                wb_dat_w <= inv ? ~s_next : s_next;
                                wb_cti <= (beat == BURST - 2) ? 3'b111 : 3'b010;
                            end
                        end
                    end
                end
                default: st <= S_RESET;
            endcase
        end
    end
endmodule
