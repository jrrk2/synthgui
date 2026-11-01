// RAMB36E1.v — Minimal Verilator-compatible behavioral model
//
// Models the TDP subset used by heavyhash_matrix:
//   - True dual-port, single clock
//   - 36-bit wide mode (READ/WRITE_WIDTH = 36)
//   - DOA_REG/DOB_REG parameterized (0 or 1)
//   - WRITE_MODE_A = "READ_FIRST"
//   - Port A: read + write, Port B: read only
//
// Address decoding: 36-bit mode uses ADDR[14:5] as 10-bit word address.
// We implement 1024 x 32 storage (parity bits stored but typically unused).

module RAMB36E1 #(
    parameter RAM_MODE            = "TDP",
    parameter integer READ_WIDTH_A  = 36,
    parameter integer READ_WIDTH_B  = 36,
    parameter integer WRITE_WIDTH_A = 36,
    parameter integer WRITE_WIDTH_B = 36,
    parameter integer DOA_REG       = 0,
    parameter integer DOB_REG       = 0,
    parameter WRITE_MODE_A        = "READ_FIRST",
    parameter WRITE_MODE_B        = "WRITE_FIRST",
    parameter SIM_COLLISION_CHECK = "ALL",
    // INIT parameters (ignored in this model)
    parameter [35:0] INIT_A       = 36'h0,
    parameter [35:0] INIT_B       = 36'h0,
    parameter [35:0] SRVAL_A      = 36'h0,
    parameter [35:0] SRVAL_B      = 36'h0
) (
    // Port A
    input         CLKARDCLK,
    input         ENARDEN,
    input         REGCEAREGCE,
    input         RSTRAMARSTRAM,
    input         RSTREGARSTREG,
    input  [15:0] ADDRARDADDR,
    input  [31:0] DIADI,
    input  [3:0]  DIPADIP,
    input  [3:0]  WEA,
    output reg [31:0] DOADO,
    output reg [3:0]  DOPADOP,
    // Port B
    input         CLKBWRCLK,
    input         ENBWREN,
    input         REGCEB,
    input         RSTRAMB,
    input         RSTREGB,
    input  [15:0] ADDRBWRADDR,
    input  [31:0] DIBDI,
    input  [3:0]  DIPBDIP,
    input  [7:0]  WEBWE,
    output reg [31:0] DOBDO,
    output reg [3:0]  DOPBDOP,
    // Cascade (unused — active low tie-off)
    input         CASCADEINA,
    input         CASCADEINB,
    output        CASCADEOUTA,
    output        CASCADEOUTB
);

    // 1024 x 36 storage (32 data + 4 parity)
    reg [31:0] mem  [0:1023];
    reg [3:0]  memp [0:1023];

    // Address decode: 36-bit mode → word address = ADDR[14:5]
    wire [9:0] addr_a = ADDRARDADDR[14:5];
    wire [9:0] addr_b = ADDRBWRADDR[14:5];

    // Internal latch outputs (before optional output register)
    reg [31:0] do_a_latch, do_b_latch;
    reg [3:0]  dop_a_latch, dop_b_latch;

    // Port A: READ_FIRST — read old value, then write
    always @(posedge CLKARDCLK) begin
        if (ENARDEN) begin
            if (RSTRAMARSTRAM) begin
                do_a_latch  <= INIT_A[31:0];
                dop_a_latch <= INIT_A[35:32];
            end else begin
                // Read (always, before write)
                do_a_latch  <= mem[addr_a];
                dop_a_latch <= memp[addr_a];
                // Write (byte-granular)
                if (WEA[0]) mem[addr_a][ 7: 0] <= DIADI[ 7: 0];
                if (WEA[1]) mem[addr_a][15: 8] <= DIADI[15: 8];
                if (WEA[2]) mem[addr_a][23:16] <= DIADI[23:16];
                if (WEA[3]) mem[addr_a][31:24] <= DIADI[31:24];
                if (|WEA)   memp[addr_a]       <= DIPADIP;
            end
        end
    end

    // Port B: read only in our usage (WEBWE tied to 0)
    always @(posedge CLKBWRCLK) begin
        if (ENBWREN) begin
            if (RSTRAMB) begin
                do_b_latch  <= INIT_B[31:0];
                dop_b_latch <= INIT_B[35:32];
            end else begin
                do_b_latch  <= mem[addr_b];
                dop_b_latch <= memp[addr_b];
            end
        end
    end

    // Output register stage (DOA_REG=1 / DOB_REG=1)
    generate
        if (DOA_REG == 1) begin : gen_doa_reg
            always @(posedge CLKARDCLK) begin
                if (RSTREGARSTREG) begin
                    DOADO   <= SRVAL_A[31:0];
                    DOPADOP <= SRVAL_A[35:32];
                end else if (REGCEAREGCE) begin
                    DOADO   <= do_a_latch;
                    DOPADOP <= dop_a_latch;
                end
            end
        end else begin : gen_doa_noreg
            always @(*) begin
                DOADO   = do_a_latch;
                DOPADOP = dop_a_latch;
            end
        end

        if (DOB_REG == 1) begin : gen_dob_reg
            always @(posedge CLKBWRCLK) begin
                if (RSTREGB) begin
                    DOBDO   <= SRVAL_B[31:0];
                    DOPBDOP <= SRVAL_B[35:32];
                end else if (REGCEB) begin
                    DOBDO   <= do_b_latch;
                    DOPBDOP <= dop_b_latch;
                end
            end
        end else begin : gen_dob_noreg
            always @(*) begin
                DOBDO   = do_b_latch;
                DOPBDOP = dop_b_latch;
            end
        end
    endgenerate

    // Cascade outputs unused
    assign CASCADEOUTA = 1'b0;
    assign CASCADEOUTB = 1'b0;

    // Initialize memory to zero
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin
            mem[i]  = 32'h0;
            memp[i] = 4'h0;
        end
        do_a_latch = 32'h0;
        dop_a_latch = 4'h0;
        do_b_latch = 32'h0;
        dop_b_latch = 4'h0;
        DOADO   = 32'h0;
        DOPADOP = 4'h0;
        DOBDO   = 32'h0;
        DOPBDOP = 4'h0;
    end

endmodule
