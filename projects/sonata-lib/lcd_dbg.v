// Debug console for the Sonata board's 160x128 ST7735 LCD.
//
// A title bar and 15 lines of "LABEL XXXXXXXX": a four character label and a
// 32-bit word in hex, optionally followed by PASS / FAIL / RUN.  The words are sampled live; the whole panel is redrawn
// continuously, so there is no frame buffer.  Init is the vendor driver's.
//
// SPI mode 0 at clk/2 (12.5 MHz from 25 MHz; the ST7735 takes up to 15).
// SWAP_RB: the panel is set to BGR order as in the vendor driver, so the
// colours below are written with red and blue swapped; clear it if red shows blue.
module lcd_dbg #(
    parameter CLK_HZ = 25_000_000,
    parameter [8*20-1:0] TITLE = "SONATA DEBUG        ",
    parameter [8*60-1:0] LABELS = {15{"----"}},
    parameter SWAP_RB = 1
) (
    input wire clk,
    input wire rst,
    input wire [15*32-1:0] words,
    input wire [15*2-1:0] status,  // per line: 0 none, 1 PASS, 2 FAIL, 3 RUN, after the hex word
    output reg lcd_rst,
    output wire lcd_dc,
    output wire lcd_copi,
    output reg lcd_clk,
    output reg lcd_cs,
    output wire lcd_backlight
);
    localparam [10:0] FH_BASE = 9'd256;

    // ---- SPI byte engine
    reg req_t = 1'b0, ack_t = 1'b0, busy = 1'b0, ph = 1'b0, dcr = 1'b0, keepr = 1'b0;
    reg [7:0] sh = 8'h00;
    reg [3:0] bc = 4'h0;
    reg [7:0] tx_byte = 8'h00;
    reg tx_dc = 1'b0, tx_keep = 1'b0;
    wire idle = (req_t == ack_t) && !busy;

    assign lcd_copi = sh[7];
    assign lcd_dc = dcr;

    always @(posedge clk) begin
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

    // ---- sequencer
    localparam S_ROM = 4'd0, S_ROMQ = 4'd1, S_WAIT = 4'd2, S_DELAY = 4'd3,
               S_P0 = 4'd4, S_P1 = 4'd5, S_P2 = 4'd6, S_HI = 4'd7, S_LO = 4'd8;
    reg [3:0] st = S_ROM;
    reg hdr = 1'b0;
    reg [7:0] ms_left = 8'h00;
    reg [$clog2(CLK_HZ / 1000):0] tick = 0;
    reg [7:0] x = 8'h00;
    reg [6:0] y = 7'h00;
    reg [15:0] fg = 16'h0, bg = 16'h0, pix = 16'h0;

    wire [2:0] etype = rom_q[10:8];
    wire [3:0] r = y[6:3];
    wire [4:0] c = x[7:3];
    wire [3:0] wi = r - 4'd1;
    wire [31:0] word = words[wi * 32 +: 32];
    wire used = (LABELS[(59 - wi * 4) * 8 +: 8] != 8'h20);  // a blank label hides the line
    wire [3:0] nib = word[(12 - c) * 4 +: 4];
    wire [1:0] stat = status[wi * 2 +: 2];
    wire [1:0] k = c[1:0] - 2'd2;  // character of the status word at columns 14..17
    reg [7:0] stat_ch;
    always @* case ({stat, k})
        4'b0100: stat_ch = "P"; 4'b0101: stat_ch = "A"; 4'b0110: stat_ch = "S"; 4'b0111: stat_ch = "S";
        4'b1000: stat_ch = "F"; 4'b1001: stat_ch = "A"; 4'b1010: stat_ch = "I"; 4'b1011: stat_ch = "L";
        4'b1100: stat_ch = "R"; 4'b1101: stat_ch = "U"; 4'b1110: stat_ch = "N"; default: stat_ch = " ";
    endcase
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
            S_P0: begin  // which character, and its colours
                f_row <= y[2:0];
                if (r == 4'd0) begin
                    f_ch <= TITLE[(19 - c) * 8 +: 7];
                    fg <= col(WHITE);
                    bg <= col(BLACK);
                end else if (c < 5'd4) begin
                    f_ch <= LABELS[(59 - (wi * 4 + c[1:0])) * 8 +: 7];
                    fg <= col(YELLOW);
                    bg <= col(BLACK);
                end else if (c >= 5'd5 && c <= 5'd12 && used) begin
                    f_ch <= (nib < 4'd10) ? {3'd3, nib} : (7'h37 + {3'd0, nib});
                    fg <= col(GREEN);
                    bg <= col(BLACK);
                end else if (c >= 5'd14 && c <= 5'd17 && used && stat != 2'd0) begin
                    f_ch <= stat_ch[6:0];
                    fg <= col(stat == 2'd1 ? GREEN : stat == 2'd2 ? RED : YELLOW);
                    bg <= col(BLACK);
                end else begin
                    f_ch <= 7'h20;
                    fg <= col(GREEN);
                    bg <= col(BLACK);
                end
                st <= S_P1;
            end
            S_P1: st <= S_P2;  // the font ROM reads
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
