`default_nettype none
// VC707 user LEDs held at a fixed pattern: a check that the open flow's output pads on the HP banks drive.
module vc707_ledtest (output wire [7:0] led);
	assign led = 8'ha5;
endmodule
