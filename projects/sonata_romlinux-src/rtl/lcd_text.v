// Text console for the Sonata board's 160x128 ST7735 LCD: 20 columns x 16 rows of 8x8 characters kept in a RAM
// that a Wishbone master writes (byte at offset row*20+col; bit 7 of a character selects yellow instead of green,
// row 0 is white and fixed).  The panel is redrawn continuously from the RAM.  Derived from lcd_dbg.v (sonata-lib): same
// panel init (lcd_init_rom), font (lcd_font) and pixel engine, but the SPI clock is clk/4 (12.5 MHz at 50 MHz).
module lcd_text #(
    parameter CLK_HZ = 50_000_000,
    parameter SWAP_RB = 1
) (
    input wire clk,
    input wire rst,
    // bus side, write only: word index (4 characters per word), byte enables
    input wire wr,
    input wire [6:0] wa,   // word 80: scroll register (bits 3:0, 0..14)
    input wire [31:0] wd,
    input wire [3:0] wsel,
    output reg lcd_rst,
    output wire lcd_dc,
    output wire lcd_copi,
    output reg lcd_clk,
    output reg lcd_cs,
    output wire lcd_backlight
);
    localparam [10:0] FH_BASE = 9'd256;

    // ---- text RAM: four byte lanes, each one write port (bus) and one read port (panel)
    reg [7:0] m0 [0:127];
    reg [7:0] m1 [0:127];
    reg [7:0] m2 [0:127];
    reg [7:0] m3 [0:127];
    always @(posedge clk) if (wr && wsel[0]) m0[wa] <= wd[7:0];
    always @(posedge clk) if (wr && wsel[1]) m1[wa] <= wd[15:8];
    always @(posedge clk) if (wr && wsel[2]) m2[wa] <= wd[23:16];
    always @(posedge clk) if (wr && wsel[3]) m3[wa] <= wd[31:24];

    reg [3:0] scroll = 4'd0;
    always @(posedge clk)
        if (rst) scroll <= 4'd0;
        else if (wr && wa == 7'd80 && wsel[0]) scroll <= (wd[3:0] > 4'd14) ? 4'd14 : wd[3:0];

    // ---- SPI byte engine
    reg req_t = 1'b0, ack_t = 1'b0, busy = 1'b0, ph = 1'b0, dcr = 1'b0, keepr = 1'b0;
    reg [7:0] sh = 8'h00;
    reg [3:0] bc = 4'h0;
    reg [7:0] tx_byte = 8'h00;
    reg tx_dc = 1'b0, tx_keep = 1'b0;
    wire idle = (req_t == ack_t) && !busy;

    assign lcd_copi = sh[7];
    assign lcd_dc = dcr;

    reg ce = 1'b0;
    always @(posedge clk) ce <= ~ce;

    always @(posedge clk) if (ce || rst) begin
        if (rst) begin
            ack_t <= req_t;
            busy <= 1'b0;
            ph <= 1'b0;
            lcd_clk <= 1'b0;
            lcd_cs <= 1'b1;
        end else if (!busy) begin
            if (req_t != ack_t) begin
                ack_t <= req_t;
                sh <= tx_byte;
                dcr <= tx_dc;
                keepr <= tx_keep;
                busy <= 1'b1;
                lcd_cs <= 1'b0;
                bc <= 4'h0;
                ph <= 1'b0;
            end
        end else if (!ph) begin
            lcd_clk <= 1'b1;
            ph <= 1'b1;
        end else begin
            lcd_clk <= 1'b0;
            ph <= 1'b0;
            sh <= {sh[6:0], 1'b0};
            bc <= bc + 4'h1;
            if (bc == 4'h7) begin
                busy <= 1'b0;
                if (!keepr) lcd_cs <= 1'b1;
            end
        end
    end

    // ---- ROMs
    reg [8:0] rom_a = 9'd0;
    wire [10:0] rom_q;
    lcd_init_rom rom (.clk(clk), .a(rom_a), .q(rom_q));

    reg [6:0] f_ch = 7'h20;
    reg [2:0] f_row = 3'h0;
    wire [7:0] f_q;
    lcd_font font (.clk(clk), .ch(f_ch), .row(f_row), .q(f_q));

    // ---- colours (RGB565)
    function [15:0] col(input [15:0] c);
        col = SWAP_RB ? {c[4:0], c[10:5], c[15:11]} : c;
    endfunction
    localparam [15:0] BLACK = 16'h0000, WHITE = 16'hFFFF, YELLOW = 16'hFFE0, GREEN = 16'h07E0, RED = 16'hF800;

    wire [2:0] etype = rom_q[10:8];

    // ---- sequencer
    localparam S_ROM = 4'd0, S_ROMQ = 4'd1, S_WAIT = 4'd2, S_DELAY = 4'd3,
               S_P0 = 4'd4, S_P1 = 4'd5, S_P2 = 4'd6, S_HI = 4'd7, S_LO = 4'd8, S_P1B = 4'd9;
    reg [3:0] st = S_ROM;
    reg hdr = 1'b0;
    reg [7:0] ms_left = 8'h00;
    reg [$clog2(CLK_HZ / 1000):0] tick = 0;
    reg [7:0] x = 8'h00;
    reg [6:0] y = 7'h00;
    reg [15:0] fg = 16'h0, bg = 16'h0, pix = 16'h0;

    wire [3:0] r = y[6:3];
    wire [4:0] c = x[7:3];
    wire [4:0] rsum = {1'b0, r - 4'd1} + {1'b0, scroll};           // k - 1 + scroll
    wire [3:0] rmod = (rsum >= 5'd15) ? rsum[3:0] - 4'd15 : rsum[3:0];
    wire [3:0] rr = (r == 4'd0) ? 4'd0 : (4'd1 + rmod);              // ram row
    wire [8:0] off = {1'b0, rr, 4'b0000} + {3'b000, rr, 2'b00} + {4'b0000, c};   // row * 20 + col
    reg [31:0] wq = 32'h0;
    reg [1:0] lane_q = 2'd0;
    always @(posedge clk) begin
        wq <= {m3[off[8:2]], m2[off[8:2]], m1[off[8:2]], m0[off[8:2]]};
        lane_q <= off[1:0];
    end
    wire [7:0] tch = wq[lane_q * 8 +: 8];
    wire last_px = (x == 8'd159) && (y == 7'd127);

    assign lcd_backlight = hdr;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_ROM;
            rom_a <= 9'd0;
            hdr <= 1'b0;
            lcd_rst <= 1'b1;
        end else case (st)
            S_ROM: st <= S_ROMQ;
            S_ROMQ: case (etype)
                3'd0, 3'd1, 3'd4: if (idle) begin
                    tx_byte <= rom_q[7:0];
                    tx_dc <= (etype == 3'd1);
                    tx_keep <= (etype == 3'd4);
                    req_t <= ~req_t;
                    rom_a <= rom_a + 9'd1;
                    st <= S_ROM;
                end
                3'd2: begin
                    ms_left <= rom_q[7:0];
                    tick <= 0;
                    rom_a <= rom_a + 9'd1;
                    st <= S_DELAY;
                end
                3'd5, 3'd6: begin
                    lcd_rst <= (etype == 3'd6);
                    rom_a <= rom_a + 9'd1;
                    st <= S_ROM;
                end
                default: begin  // end of list: init, then each frame's header, then the pixels
                    if (!hdr) begin
                        hdr <= 1'b1;
                        rom_a <= FH_BASE[8:0];
                        st <= S_ROM;
                    end else if (idle) begin
                        rom_a <= FH_BASE[8:0];
                        x <= 8'd0;
                        y <= 7'd0;
                        st <= S_P0;
                    end
                end
            endcase
            S_DELAY:
                if (ms_left == 8'd0) st <= S_ROM;
                else if (tick == CLK_HZ / 1000 - 1) begin
                    tick <= 0;
                    ms_left <= ms_left - 8'd1;
                end else tick <= tick + 1;
            S_P0: begin  // the text RAM reads the character at (r, c)
                f_row <= y[2:0];
                st <= S_P1;
            end
            S_P1: begin  // which character, and its colours
                f_ch <= tch[6:0];
                fg <= (r == 4'd0) ? col(WHITE) : tch[7] ? col(YELLOW) : col(GREEN);
                bg <= col(BLACK);
                st <= S_P1B;
            end
            S_P1B: st <= S_P2;  // the font ROM reads
            S_P2: begin
                pix <= f_q[x[2:0]] ? fg : bg;
                st <= S_HI;
            end
            S_HI: if (idle) begin
                tx_byte <= pix[15:8];
                tx_dc <= 1'b1;
                tx_keep <= 1'b1;
                req_t <= ~req_t;
                st <= S_LO;
            end
            S_LO: if (idle) begin
                tx_byte <= pix[7:0];
                tx_dc <= 1'b1;
                tx_keep <= !last_px;
                req_t <= ~req_t;
                if (last_px) st <= S_ROM;
                else begin
                    if (x == 8'd159) begin
                        x <= 8'd0;
                        y <= y + 7'd1;
                    end else x <= x + 8'd1;
                    st <= S_P0;
                end
            end
            default: st <= S_ROM;
        endcase
    end
endmodule
