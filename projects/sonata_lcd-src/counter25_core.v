module counter25_core (
    input wire clk,
    input wire rst,
    output wire [7:0] led
);
    // 25 MHz / 2^22 = one Johnson step every 168 ms
    reg [21:0] div = 22'h0;
    wire tick = &div;

    always @(posedge clk)
        if (rst)
            div <= 22'h0;
        else
            div <= div + 22'h1;

    reg [7:0] johnson = 8'h00;
    always @(posedge clk)
        if (rst)
            johnson <= 8'h00;
        else if (tick)
            johnson <= {johnson[6:0], ~johnson[7]};

    assign led = johnson;
endmodule
