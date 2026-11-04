// ICAP smoke test: read configuration registers through ICAPE2, no CPU.
// Every ~0.7 s prints over the UART (115200 8N1):
//   ICAP id=XXXXXXXX stat=XXXXXXXX ctl0=XXXXXXXX
// The IDCODE reaching the fabric proves both directions of the ICAP work: the
// read request goes in through I, the answer comes back through O.  Three
// registers, because a stuck read path would show the same value in all three.
// All state powers up zero (no reset needed).  The ICAP swaps the bits within
// each byte, on both I and O.
module icap_smoke #(
    parameter [27:0] EXPECT_ID = 28'h362C093,  // low 28 bits, the top nibble is the revision
    parameter [8:0]  BAUD_DIV  = 9'd217,       // 25 MHz / 115200
    parameter [24:0] PERIOD    = 25'd17000000
) (
    input  wire        clk,
    output wire        tx,
    output wire [7:0]  led,
    output wire [31:0] icap_i,
    output wire        icap_csib,
    output wire        icap_rdwrb,
    input  wire [31:0] icap_o
);
    function [31:0] bswap(input [31:0] w);
        integer b;
        for (b = 0; b < 8; b = b + 1) begin
            bswap[b]      = w[7 - b];
            bswap[8 + b]  = w[15 - b];
            bswap[16 + b] = w[23 - b];
            bswap[24 + b] = w[31 - b];
        end
    endfunction
    function [7:0] hexc(input [3:0] n);
        hexc = n < 10 ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    localparam [31:0] NOOP = 32'h20000000, SYNC = 32'hAA995566, DUMMY = 32'hFFFFFFFF;
    localparam [31:0] CMD_WR = 32'h30008001, DESYNC = 32'h0000000D;

    reg [24:0] timer = 0;
    reg [4:0]  step  = 0;       // 0: idle
    reg [1:0]  which = 0;       // the register being read
    reg        running = 0;
    reg        sending = 0;
    reg [31:0] r0 = 0, r1 = 0, r2 = 0;
    wire [4:0] reg_addr = which == 0 ? 5'd12 : which == 1 ? 5'd7 : 5'd5;
    wire [31:0] rd_hdr = 32'h28000001 | ({27'd0, reg_addr} << 13);

    reg [31:0] di;
    reg        csib, rdwrb;
    always @* begin
        di = DUMMY; csib = 1'b1; rdwrb = 1'b0;
        case (step)
            1:  begin csib = 0; di = DUMMY; end
            2:  begin csib = 0; di = SYNC; end
            3:  begin csib = 0; di = NOOP; end
            4:  begin csib = 0; di = NOOP; end
            5:  begin csib = 0; di = rd_hdr; end
            6:  begin csib = 0; di = NOOP; end
            7:  begin csib = 0; di = NOOP; end
            8:  begin csib = 1; rdwrb = 1; di = NOOP; end   // turn the bus round
            9:  begin csib = 0; rdwrb = 1; di = NOOP; end
            10: begin csib = 0; rdwrb = 1; di = NOOP; end
            11: begin csib = 0; rdwrb = 1; di = NOOP; end
            12: begin csib = 0; rdwrb = 1; di = NOOP; end
            13: begin csib = 0; rdwrb = 1; di = NOOP; end   // captured here
            14: begin csib = 1; rdwrb = 1; di = NOOP; end
            15: begin csib = 1; rdwrb = 0; di = NOOP; end
            16: begin csib = 0; di = CMD_WR; end
            17: begin csib = 0; di = DESYNC; end
            18: begin csib = 0; di = NOOP; end
            19: begin csib = 0; di = NOOP; end
            default: ;
        endcase
    end
    assign icap_i = bswap(di);
    assign icap_csib = csib;
    assign icap_rdwrb = rdwrb;
    wire [31:0] rd = bswap(icap_o);

    // the message: 46 characters
    reg  [5:0] ci = 0;
    wire [31:0] rv = ci < 16 ? r0 : ci < 30 ? r1 : r2;
    wire [2:0] nib = ci < 16 ? 3'd7 - (ci - 6'd8) : ci < 30 ? 3'd7 - (ci - 6'd22) : 3'd7 - (ci - 6'd36);
    wire [3:0] nv = rv[4 * nib + 3 -: 4];
    reg  [7:0] ch;
    always @* begin
        case (ci)
            0: ch = "I"; 1: ch = "C"; 2: ch = "A"; 3: ch = "P"; 4: ch = " ";
            5: ch = "i"; 6: ch = "d"; 7: ch = "=";
            16: ch = " "; 17: ch = "s"; 18: ch = "t"; 19: ch = "a"; 20: ch = "t"; 21: ch = "=";
            30: ch = " "; 31: ch = "c"; 32: ch = "t"; 33: ch = "l"; 34: ch = "0"; 35: ch = "=";
            44: ch = 8'h0D; 45: ch = 8'h0A;
            default: ch = hexc(nv);
        endcase
    end

    // UART
    reg [8:0] bdiv = 0;
    reg [3:0] bitn = 0;         // 0: idle
    reg [8:0] shreg = 9'h1FF;
    assign tx = shreg[0];

    always @(posedge clk) begin
        timer <= timer + 1'b1;
        if (!running && !sending && timer == PERIOD) begin
            timer <= 0; running <= 1; which <= 0; step <= 1;
        end
        if (running) begin
            step <= step + 1'b1;
            if (step == 13) begin
                if (which == 0) r0 <= rd;
                if (which == 1) r1 <= rd;
                if (which == 2) r2 <= rd;
            end
            if (step == 20) begin
                step <= 0;
                if (which == 2) begin running <= 0; sending <= 1; ci <= 0; end
                else begin which <= which + 1'b1; step <= 1; end
            end
        end
        if (bitn != 0) begin
            bdiv <= bdiv + 1'b1;
            if (bdiv == BAUD_DIV - 1) begin
                bdiv <= 0; shreg <= {1'b1, shreg[8:1]}; bitn <= bitn - 1'b1;
            end
        end else if (sending) begin
            shreg <= {ch, 1'b0}; bitn <= 4'd10; bdiv <= 0;
            if (ci == 45) sending <= 0; else ci <= ci + 1'b1;
        end
    end

    // LEDs: polarity-free.  led[0] slow heartbeat (the bitstream runs); led[1] blinks
    // only if the IDCODE matched; led[2] blinks only if O ever read non-zero.
    reg [24:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;
    wire ok_id = r0[27:0] == EXPECT_ID;
    wire ok_nz = r0 != 0;
    assign led = {5'b0, ok_nz & blink[22], ok_id & blink[21], blink[24]};
endmodule
