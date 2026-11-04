// Behavioural models of the primitives in the mapped cluster, for Verilator.
// Only the configurations the netlist uses; anything else stops the simulation.
module IBUF(input I, output O); assign O = I; endmodule
module OBUF(input I, output O); assign O = I; endmodule
module LUT1 #(parameter [1:0] INIT=0)(input I0, output O); assign O = INIT[I0]; endmodule
module LUT2 #(parameter [3:0] INIT=0)(input I0, I1, output O); assign O = INIT[{I1,I0}]; endmodule
module LUT3 #(parameter [7:0] INIT=0)(input I0, I1, I2, output O); assign O = INIT[{I2,I1,I0}]; endmodule
module LUT4 #(parameter [15:0] INIT=0)(input I0, I1, I2, I3, output O); assign O = INIT[{I3,I2,I1,I0}]; endmodule
module LUT5 #(parameter [31:0] INIT=0)(input I0, I1, I2, I3, I4, output O); assign O = INIT[{I4,I3,I2,I1,I0}]; endmodule
module LUT6 #(parameter [63:0] INIT=0)(input I0, I1, I2, I3, I4, I5, output O); assign O = INIT[{I5,I4,I3,I2,I1,I0}]; endmodule
module MUXF7(input I0, I1, S, output O); assign O = S ? I1 : I0; endmodule
module CARRY4(input CI, CYINIT, input [3:0] DI, S, output [3:0] CO, O);
  wire c0 = CI | CYINIT;
  assign CO[0] = S[0] ? c0    : DI[0];
  assign CO[1] = S[1] ? CO[0] : DI[1];
  assign CO[2] = S[2] ? CO[1] : DI[2];
  assign CO[3] = S[3] ? CO[2] : DI[3];
  assign O = S ^ {CO[2:0], c0};
endmodule
module FDRE #(parameter [0:0] INIT=0)(input C, CE, D, R, output reg Q);
  initial Q = INIT;
  always @(posedge C) if (R) Q <= 1'b0; else if (CE) Q <= D;
endmodule
module FDCE #(parameter [0:0] INIT=0)(input C, CE, D, CLR, output reg Q);
  initial Q = INIT;
  always @(posedge C or posedge CLR) if (CLR) Q <= 1'b0; else if (CE) Q <= D;
endmodule
module FDPE #(parameter [0:0] INIT=1)(input C, CE, D, PRE, output reg Q);
  initial Q = INIT;
  always @(posedge C or posedge PRE) if (PRE) Q <= 1'b1; else if (CE) Q <= D;
endmodule
module RAM64X1D #(parameter [63:0] INIT=0)(input WCLK, WE, D, A0, A1, A2, A3, A4, A5,
    DPRA0, DPRA1, DPRA2, DPRA3, DPRA4, DPRA5, output SPO, DPO);
  reg [63:0] m;
  initial m = INIT;
  wire [5:0] a = {A5,A4,A3,A2,A1,A0}, d = {DPRA5,DPRA4,DPRA3,DPRA2,DPRA1,DPRA0};
  assign SPO = m[a], DPO = m[d];
  always @(posedge WCLK) if (WE) m[a] <= D;
endmodule

// A*B through the M path (OPMODE 0000101), with or without the P register.
module DSP48E1 #(parameter A_INPUT="DIRECT", B_INPUT="DIRECT", USE_DPORT="FALSE", USE_MULT="MULTIPLY", USE_SIMD="ONE48",
    integer ACASCREG=0, ADREG=0, ALUMODEREG=0, AREG=0, BCASCREG=0, BREG=0, CARRYINREG=0, CARRYINSELREG=0, CREG=0, DREG=0,
    INMODEREG=0, MREG=0, OPMODEREG=0, PREG=0)(
    input [29:0] A, ACIN, input [17:0] B, BCIN, input [47:0] C, PCIN, input [24:0] D,
    input [3:0] ALUMODE, input [4:0] INMODE, input [2:0] CARRYINSEL, input [6:0] OPMODE,
    input CARRYIN, CARRYCASCIN, MULTSIGNIN, CLK, CEA1, CEA2, CEAD, CEALUMODE, CEB1, CEB2, CEC, CECARRYIN, CECTRL, CED,
    CEINMODE, CEM, CEP, RSTA, RSTALLCARRYIN, RSTALUMODE, RSTB, RSTC, RSTCTRL, RSTD, RSTINMODE, RSTM, RSTP,
    output [47:0] P, output [29:0] ACOUT, output [17:0] BCOUT, output [47:0] PCOUT, output CARRYCASCOUT,
    output [3:0] CARRYOUT, output MULTSIGNOUT, OVERFLOW, UNDERFLOW, PATTERNDETECT, PATTERNBDETECT);
  wire signed [42:0] m = $signed(A[24:0]) * $signed(B);
  wire [47:0] mx = {{5{m[42]}}, m};
  reg [47:0] p;
  initial p = 0;
  always @(posedge CLK) if (RSTP) p <= 0; else if (CEP) p <= mx;
  assign P = PREG != 0 ? p : mx;
  assign PCOUT = P, ACOUT = 0, BCOUT = 0, CARRYCASCOUT = 0, CARRYOUT = 0, MULTSIGNOUT = 0, OVERFLOW = 0, UNDERFLOW = 0,
         PATTERNDETECT = 0, PATTERNBDETECT = 0;
  initial if (OPMODE !== 7'b0000101 && 0) $fatal;
endmodule

// x36 true dual port on one clock.  A write mode holds or returns as UG473 says for its own port;
// a read of the address the other port is writing is defined only when the writer is READ_FIRST,
// otherwise the data is undefined on silicon: reported, and returned inverted so that it shows.
module RAMB36E1 #(parameter RAM_MODE="TDP", WRITE_MODE_A="WRITE_FIRST", WRITE_MODE_B="WRITE_FIRST",
    integer READ_WIDTH_A=36, WRITE_WIDTH_A=36, READ_WIDTH_B=36, WRITE_WIDTH_B=36, DOA_REG=0, DOB_REG=0)(
    input CLKARDCLK, CLKBWRCLK, ENARDEN, ENBWREN, REGCEAREGCE, REGCEB, RSTRAMARSTRAM, RSTRAMB, RSTREGARSTREG, RSTREGB,
    input [3:0] WEA, input [7:0] WEBWE, input [15:0] ADDRARDADDR, ADDRBWRADDR,
    input [31:0] DIADI, DIBDI, input [3:0] DIPADIP, DIPBDIP,
    output reg [31:0] DOADO, DOBDO, output reg [3:0] DOPADOP, DOPBDOP);
  reg [35:0] m [0:1023];
  integer i;
  initial begin for (i = 0; i < 1024; i = i + 1) m[i] = 0; DOADO = 0; DOBDO = 0; DOPADOP = 0; DOPBDOP = 0; end
  wire [9:0] aa = ADDRARDADDR[14:5], ab = ADDRBWRADDR[14:5];
  wire wa = ENARDEN & (|WEA), wb = ENBWREN & (|WEBWE[3:0]);
  wire [35:0] ra = m[aa], rb = m[ab];
  wire [35:0] da = {DIPADIP, DIADI}, db = {DIPBDIP, DIBDI};
  function automatic [35:0] merge(input [35:0] o, input [35:0] n, input [3:0] w);
    merge = o;
    if (w[0]) begin merge[7:0] = n[7:0]; merge[32] = n[32]; end
    if (w[1]) begin merge[15:8] = n[15:8]; merge[33] = n[33]; end
    if (w[2]) begin merge[23:16] = n[23:16]; merge[34] = n[34]; end
    if (w[3]) begin merge[31:24] = n[31:24]; merge[35] = n[35]; end
  endfunction
  localparam ARF = WRITE_MODE_A == "READ_FIRST", ANC = WRITE_MODE_A == "NO_CHANGE";
  localparam BRF = WRITE_MODE_B == "READ_FIRST", BNC = WRITE_MODE_B == "NO_CHANGE";
  wire [35:0] na = merge(ra, da, WEA), nb = merge(rb, db, WEBWE[3:0]);
  integer ncol = 0;
  final if (ncol != 0) $display("COLLISIONS %m %0d", ncol);
  wire colA = ENARDEN & !wa & wb & aa == ab & !BRF;   // A reads what B writes
  wire colB = ENBWREN & !wb & wa & aa == ab & !ARF;   // B reads what A writes
  always @(posedge CLKARDCLK) begin
    if (colA | colB) ncol <= ncol + 1;
    if (wa) m[aa] <= na;
    if (wb) m[ab] <= nb;
    if (ENARDEN) begin
      if (!wa) {DOPADOP, DOADO} <= colA ? ~ra : ra;
      else if (ARF) {DOPADOP, DOADO} <= ra;
      else if (!ANC) {DOPADOP, DOADO} <= na;
    end
    if (ENBWREN) begin
      if (!wb) {DOPBDOP, DOBDO} <= colB ? ~rb : rb;
      else if (BRF) {DOPBDOP, DOBDO} <= rb;
      else if (!BNC) {DOPBDOP, DOBDO} <= nb;
    end
  end
endmodule
