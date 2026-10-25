`default_nettype none
// Static probe of the VC707's linear BPI flash (U3): an asynchronous array read held on the pins, shown on the LEDs.
//   DIP 5..0   flash word address bits A1..A6 (the rest of the address is 0; SW11 picks the boot slot through A25/A24)
//   DIP 6      0: LEDs show DQ[7:0], 1: LEDs show DQ[15:8]
//   DIP 7      1: deselect the flash (CE_B high), so it releases the bus
// Nothing is ever written: WE_B stays high.
module vc707_flashprobe (
	input  wire [7:0]  dip,
	input  wire [15:0] dq,
	output wire [23:0] addr,
	output wire        ce_n,
	output wire        oe_n,
	output wire        we_n,
	output wire        adv_n,
	output wire [7:0]  led
);
	assign addr  = {18'b0, dip[5:0]};
	assign ce_n  = dip[7];
	assign oe_n  = 1'b0;
	assign we_n  = 1'b1;
	assign adv_n = 1'b0;
	assign led   = dip[6] ? dq[15:8] : dq[7:0];
endmodule
