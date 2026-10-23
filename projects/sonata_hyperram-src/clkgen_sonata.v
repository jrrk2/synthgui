// Sonata: 25 MHz board clock -> 80 MHz (the HyperRAM core; the HyperRAM clock is a quarter of this)
// and 25 MHz (LCD).  800 MHz VCO.  The core closes timing in this flow at about 83 MHz.  The topology is the one the VC707 designs use in this flow
// (ZHOLD compensation, direct feedback).
module clkgen_sonata (
    input wire clk_in,
    input wire rst,
    output wire clk80,
    output wire clk25,
    output wire locked
);
    wire fb, c80, c25;

    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"),
        .COMPENSATION("ZHOLD"),
        .STARTUP_WAIT("FALSE"),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(32.000),
        .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(10.000),
        .CLKOUT0_PHASE(0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT1_DIVIDE(32),
        .CLKOUT1_PHASE(0.000),
        .CLKOUT1_DUTY_CYCLE(0.500),
        .CLKIN1_PERIOD(40.000)
    ) mmcm (
        .CLKFBOUT(fb), .CLKFBOUTB(),
        .CLKOUT0(c80), .CLKOUT0B(), .CLKOUT1(c25), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBIN(fb),
        .CLKIN1(clk_in), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .DADDR(7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0), .DO(), .DRDY(), .DWE(1'b0),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
        .CLKINSTOPPED(), .CLKFBSTOPPED(),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(rst)
    );

    BUFG bufg80 (.I(c80), .O(clk80));
    BUFG bufg25 (.I(c25), .O(clk25));
endmodule
