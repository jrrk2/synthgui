module routethru_core (
    input wire clk,
    input wire rst,
    output reg [7:0] led
);
    reg [31:0] lfsr;
    always @(posedge clk)
        if (rst) lfsr <= 32'h1;
        else lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    // accumulators: S = acc ^ din (a LUT), DI = a flop output -> bypass pin
    reg [15:0] acc0, acc1, acc2, acc3;
    always @(posedge clk)
        if (rst) begin acc0 <= 0; acc1 <= 0; acc2 <= 0; acc3 <= 0; end
        else begin
            acc0 <= acc0 + lfsr[15:0];
            acc1 <= acc1 + lfsr[31:16];
            acc2 <= acc2 + {lfsr[7:0], lfsr[23:16]};
            acc3 <= acc3 + lfsr[23:8];
        end

    // flop-to-flop shift registers: every D is a fabric net
    reg [31:0] sr0, sr1, sr2, sr3;
    always @(posedge clk) begin
        sr0 <= {sr0[30:0], lfsr[0]};
        sr1 <= {sr1[30:0], lfsr[9]};
        sr2 <= {sr2[30:0], lfsr[18]};
        sr3 <= {sr3[30:0], lfsr[27]};
    end

    // slow divider so the LEDs are visible
    reg [26:0] div;
    always @(posedge clk) div <= div + 1;
    always @(posedge clk)
        if (div == 0)
            led <= {^acc0, ^acc1, ^acc2, ^acc3, sr0[31], sr1[31], sr2[31] ^ sr3[31], ^sr0};
endmodule
