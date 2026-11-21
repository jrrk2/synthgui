// The Sonata's 160x128 LCD as a binary file of the CDC 6000 Pascal runtime.
//
// A Pascal program declares     LCD[OUT] : FILE OF INTEGER;     and writes     LCD^ := word; PUT(LCD)     : the runtime's PUTB
// then stores the file's name (the declared identifier, 'LCD' in display code) in IO_FILE and the word in IO_FWORD, which
// the core presents as fo_valid / fo_name / fo_word.  This module takes the words of a file called LCD and leaves every
// other file to the UART (hit says which).  Words, as a 60-bit integer:
//
//     bits 15:0   RGB565 colour
//     bits 23:16  x, 0..159          (ignored for a fill)
//     bits 31:24  y, 0..127          (a plot outside the panel is dropped)
//     bit  32     1 = fill the whole panel with the colour, 0 = plot one pixel
//
// so  LCD^ := colour + 65536 * (x + 256 * y)  plots, and  LCD^ := colour + 4294967296  clears.  A fill takes 10240 clocks;
// busy is high meanwhile and the core waits (fo_ready) rather than lose the words that follow.
//
// The panel itself is lcd_text.v of sonata_romlinux-src, unchanged: it redraws the panel from its frame buffer
// (two RGB565 pixels a word, written with byte enables) over SPI, with its mode register set once to show the frame
// buffer rather than its text console.  The frame buffer starts with the boot logo.
module cdc_lcd #(
    parameter CLK_HZ = 12_500_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        fo_valid,
    input  wire [59:0] fo_name,
    input  wire [59:0] fo_word,
    output wire        hit,        // this file word is the display's (valid with fo_valid)
    output wire        busy,
    output wire        lcd_rst,
    output wire        lcd_dc,
    output wire        lcd_copi,
    output wire        lcd_clk,
    output wire        lcd_cs,
    output wire        lcd_backlight
);
    localparam [59:0] LCD_NAME = {6'd12, 6'd3, 6'd4, 42'd0};   // 'LCD' left justified in display code
    assign hit = (fo_name == LCD_NAME);

    // pixel number y * 160 + x = 128 y + 32 y + x; the word is that / 2, the low bit picks the half
    wire [7:0]  px = fo_word[23:16];
    wire [7:0]  py = fo_word[31:24];
    wire [14:0] pn = {py[6:0], 7'd0} + {2'd0, py[6:0], 5'd0} + {7'd0, px};
    wire        on_panel = (px < 8'd160) && !py[7];

    reg         fwr = 1'b0;
    reg  [13:0] fwa = 14'd0;
    reg  [31:0] fwd = 32'd0;
    reg  [3:0]  fwsel = 4'd0;
    reg         filling = 1'b0;
    reg  [13:0] fill_n = 14'd0;
    reg  [15:0] fill_c = 16'd0;
    assign busy = filling;

    // the text-side write that sets the mode register (word 81, bit 0) once, after reset
    reg         wr = 1'b0, mode_set = 1'b0;

    always @(posedge clk) begin
        fwr <= 1'b0;
        wr  <= 1'b0;
        if (rst) begin
            filling <= 1'b0;
            mode_set <= 1'b0;
        end else begin
            if (!mode_set) begin wr <= 1'b1; mode_set <= 1'b1; end
            if (filling) begin
                fwr <= 1'b1; fwa <= fill_n; fwd <= {fill_c, fill_c}; fwsel <= 4'b1111;
                if (fill_n == 14'd10239) filling <= 1'b0; else fill_n <= fill_n + 14'd1;
            end else if (fo_valid && hit) begin
                if (fo_word[32]) begin
                    filling <= 1'b1; fill_n <= 14'd0; fill_c <= fo_word[15:0];
                end else if (on_panel) begin
                    fwr <= 1'b1; fwa <= pn[14:1]; fwd <= {fo_word[15:0], fo_word[15:0]};
                    fwsel <= pn[0] ? 4'b1100 : 4'b0011;
                end
            end
        end
    end

    lcd_text #(.CLK_HZ(CLK_HZ)) panel (
        .clk(clk), .rst(rst),
        .wr(wr), .wa(7'd81), .wd(32'd1), .wsel(4'b0001),
        .fwr(fwr), .fwa(fwa), .fwd(fwd), .fwsel(fwsel),
        .lcd_rst(lcd_rst), .lcd_dc(lcd_dc), .lcd_copi(lcd_copi), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_backlight(lcd_backlight)
    );
endmodule
