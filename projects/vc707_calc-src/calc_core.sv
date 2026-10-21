// calc_core -- accumulator CPU with an explicitly-instantiated DSP48E1
// coprocessor (portable across front-ends; not inference-dependent).
// UNIFORM 32-bit calculator (operands & results 32-bit).  Multiply runs on the
// DSP48E1 (device-under-test) and is cross-checked against software; divide is
// software (quotient only, /0 -> 'E').
//
// ISA: ACC 8-bit, CY, PC 11-bit, 2048x8 RAM.  Operand instr = 3 bytes.
//   00 HLT 01 LDI 02 LDA 03 STA 04 ADD 05 SUB 06 IN 07 OUT 08 JMP 09 JZ
//   0A ADC 0B SBC 0C JC 0D JNZ 0E ROR
//   DSP48E1 load/read: 0F PSHA(dspA<<=8|acc) 10 PSHB(dspB<<=8|acc)
//                      13 PSHC(dspC<<=8|acc) 12 POPP(acc<=P[7:0]; P>>=8)
//   DSP48E1 operate:   opcodes 80..FF -> drive DSP48E1 OPMODE = opcode[6:0],
//     wait the pipeline, capture P.  DMUL = 0x85 (OPMODE 0x05 => P=A*B).  Other
//     opcodes reach the DSP48E1's esoteric ALU/MACC modes.
module calc_core #(
    parameter AUTOSTART = 1'b0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output wire        rx_rd,
    output reg  [7:0]  tx_byte,
    output reg         tx_stb,
    input  wire        tx_rdy,
    output wire [7:0]  led,
    output wire        tx_pin    // bit-banged UART TX (driven by OP_OUTT)
);
    localparam [7:0] OP_HLT=8'h00, OP_LDI=8'h01, OP_LDA=8'h02, OP_STA=8'h03,
                     OP_ADD=8'h04, OP_SUB=8'h05, OP_IN =8'h06, OP_OUT=8'h07,
                     OP_JMP=8'h08, OP_JZ =8'h09, OP_ADC=8'h0A, OP_SBC=8'h0B,
                     OP_JC =8'h0C, OP_JNZ=8'h0D, OP_ROR=8'h0E,
                     OP_PSHA=8'h0F, OP_PSHB=8'h10, OP_POPP=8'h12, OP_PSHC=8'h13,
                     OP_OUTL=8'h14,   // write ACC to the LED register (NOARG)
                     // --- timer/interrupt for accurate timed I/O (all NOARG) ---
                     OP_TMRLO=8'h15,  // tmr_rel[7:0]  <= acc
                     OP_TMRHI=8'h16,  // tmr_rel[15:8] <= acc; load counter; start
                     OP_EI =8'h17,    // enable timer interrupt
                     OP_DI =8'h18,    // disable timer interrupt
                     OP_RETI=8'h19,   // return from ISR (restore PC + shadow {cy,acc})
                     OP_OUTT=8'h1A,   // drive the tx pin from acc[0] (bit-bang UART TX)
                     OP_TSYNC=8'h1B;  // arm timer: hold at SEED until next rx falling
                                      // edge (start bit), then run -> exact RX phase
    localparam [7:0] ESC = 8'h1B;
    localparam [10:0] ISR_VEC = 11'd256;   // timer ISR entry; main program 0..255

    (* ram_style = "block" *) reg [7:0] mem [0:2047];
    generate if (AUTOSTART) begin : g_prog
        initial begin : load
            integer k;
            for (k=0;k<2048;k=k+1) mem[k]=8'h00;
`include "calc_init.svh"
        end
    end endgenerate
    reg  [10:0] raddr_c, waddr;
    reg  [7:0]  wdata, rdo;
    reg         we;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdo <= mem[raddr_c];
    end

    // ---- DSP48E1 coprocessor (explicit primitive) ----
    reg  [15:0] dspA_r, dspB_r;
    reg  [31:0] dspC_r;
    reg  [6:0]  opmode_r;
    reg  [3:0]  alumode_r;
    reg  [4:0]  inmode_r;
    reg  [31:0] prod_rd;
    reg  [2:0]  dcnt;
    wire [47:0] dspP;
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"), .MASK(48'h3fffffffffff),
        .PATTERN(48'h000000000000), .SEL_MASK("MASK"), .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(0), .ADREG(0), .ALUMODEREG(0), .AREG(0), .BCASCREG(0), .BREG(0),
        .CARRYINREG(0), .CARRYINSELREG(0), .CREG(0), .DREG(0), .INMODEREG(0),
        .MREG(1), .OPMODEREG(0), .PREG(1)
    ) dsp (
        .CLK(clk),
        .A({14'd0, dspA_r}), .B({2'd0, dspB_r}), .C({16'd0, dspC_r}), .D(25'd0),
        .OPMODE(opmode_r), .ALUMODE(alumode_r), .INMODE(inmode_r),
        .CARRYIN(1'b0), .CARRYINSEL(3'd0),
        .ACIN(30'd0), .BCIN(18'd0), .PCIN(48'd0),
        .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
        .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b1), .CEB1(1'b0),
        .CEB2(1'b0), .CEC(1'b1), .CECARRYIN(1'b1), .CECTRL(1'b1), .CED(1'b0),
        .CEINMODE(1'b1), .CEM(1'b1), .CEP(1'b1),
        .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTB(1'b0),
        .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0), .RSTINMODE(1'b0),
        .RSTM(rst), .RSTP(rst),
        .P(dspP), .PCOUT(), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(),
        .CARRYOUT(), .OVERFLOW(), .PATTERNDETECT(), .PATTERNBDETECT(), .UNDERFLOW()
    );

    reg  [7:0]  acc, opc;
    reg  [7:0]  led_reg;   // LED output latch, written by OP_OUTL (not live acc)
    reg         tx_bit;    // bit-banged TX line, written by OP_OUTT (idle high)
    // --- programmable timer + interrupt + shadow accumulator (timed I/O) ---
    // Timer is a 16-bit Fibonacci LFSR (PRBS), NOT an arithmetic counter: shift +
    // one XOR feedback, NO carry chain -> immune to the open-flow CARRY4 encoding
    // bug that breaks binary counters (same reason lfsr_div replaced uart_baudgen).
    // Fires (tmr_if) when the LFSR reaches the programmable terminal state tmr_term;
    // period N <=> tmr_term = SEED stepped (N-1) times (assembler precomputes it).
    localparam [15:0] TMR_SEED = 16'hACE1;   // nonzero start state
    localparam [15:0] TMR_TAPS = 16'hD008;   // x^16+x^15+x^13+x^4 (maximal length)
    reg  [15:0] tmr, tmr_term;  // LFSR state + terminal (fire) state
    wire        tmr_fb = ^(tmr & TMR_TAPS);  // XOR-tree feedback (no carry)
    reg         tmr_en;         // timer running
    reg         tmr_if;         // interrupt flag (timer reached terminal)
    reg         tmr_sync;       // armed: hold LFSR at SEED until rx falling edge
    reg         rx_prev;        // previous rx level (for falling-edge detect)
    wire        rx_fall = rx_prev & ~rx_data[0];   // rx 1->0 (UART start bit)
    reg         ie;             // interrupt enable
    reg         in_isr;         // currently inside the ISR (no nesting)
    reg  [7:0]  acc_sh;         // shadow accumulator (swapped in during ISR)
    reg         cy_sh;          // shadow carry
    reg  [10:0] pc, cmd_addr;
    reg  [10:0] ret_isr;   // saved PC across the ISR
    reg  [15:0] opnd;
    reg         cy;

    localparam [4:0]
        C_IDLE=0, C_WA=1, C_WA2=2, C_WD=3, C_RA=4, C_RA2=5, C_RD=6, C_SEND=7,
        X_F1=8, X_F2=9, X_OA=10, X_OB=11, X_OC=12, X_OD=13,
        X_M1=14, X_M2=15, X_STA=16, X_OUT=17, X_IN=18, X_HALT=19, X_DW=20;
    reg [4:0] st;

    wire is_exec   = (st >= X_F1);
    wire esc_abort = rx_valid && (rx_data==ESC) && is_exec;

    always @* begin
        case (st)
            C_RA,C_RA2,C_RD: raddr_c = cmd_addr;
            X_M1:            raddr_c = opnd[10:0];
            default:         raddr_c = pc;
        endcase
    end

    assign led   = led_reg;
    assign tx_pin = tx_bit;
    assign rx_rd = esc_abort || (rx_valid && (st==C_IDLE || st==C_WA || st==C_WA2 ||
                                  st==C_WD || st==C_RA || st==C_RA2 || st==X_IN));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st<= AUTOSTART ? X_F1 : C_IDLE; acc<=0; pc<=0; we<=0; tx_stb<=0; cy<=0; led_reg<=0;
            waddr<=0; wdata<=0; cmd_addr<=0; opnd<=0; opc<=0;
            tmr<=0; tmr_term<=0; tmr_en<=0; tmr_if<=0; ie<=0; in_isr<=0;
            tmr_sync<=0; rx_prev<=1'b1;
            acc_sh<=0; cy_sh<=0; ret_isr<=0; tx_bit<=1'b1;   // tx idle high
            dspA_r<=0; dspB_r<=0; dspC_r<=0; prod_rd<=0; dcnt<=0;
            opmode_r<=0; alumode_r<=0; inmode_r<=0;
        end else begin
            we<=1'b0; tx_stb<=1'b0;
            if (esc_abort) st <= C_IDLE;
            else case (st)
            C_IDLE: if (rx_valid) begin
                        if      (rx_data=="W") st<=C_WA;
                        else if (rx_data=="R") st<=C_RA;
                        else if (rx_data=="X") begin pc<=11'd0; st<=X_F1; end
                    end
            C_WA:   if (rx_valid) begin cmd_addr[7:0]<=rx_data;       st<=C_WA2; end
            C_WA2:  if (rx_valid) begin cmd_addr[10:8]<=rx_data[2:0]; st<=C_WD;  end
            C_WD:   if (rx_valid) begin waddr<=cmd_addr; wdata<=rx_data; we<=1'b1; st<=C_IDLE; end
            C_RA:   if (rx_valid) begin cmd_addr[7:0]<=rx_data;       st<=C_RA2; end
            C_RA2:  if (rx_valid) begin cmd_addr[10:8]<=rx_data[2:0]; st<=C_RD;  end
            C_RD:   st<=C_SEND;
            C_SEND: if (tx_rdy && !tx_stb) begin tx_byte<=rdo; tx_stb<=1'b1; st<=C_IDLE; end
            X_F1:   if (ie && tmr_if && !in_isr) begin
                        // take the timer interrupt: save PC, swap in shadow {cy,acc},
                        // clear the flag, vector to the ISR (re-fetch there).
                        ret_isr<=pc; acc<=acc_sh; acc_sh<=acc; cy<=cy_sh; cy_sh<=cy;
                        in_isr<=1'b1; tmr_if<=1'b0; pc<=ISR_VEC; st<=X_F1;
                    end else st<=X_F2;
            X_F2:   begin
                        opc<=rdo; pc<=pc+11'd1;
                        if (rdo[7]) begin                 // 0x80..0xFF = DSP48E1 op
                            opmode_r<=rdo[6:0]; alumode_r<=4'd0; inmode_r<=5'd0;
                            dcnt<=3'd5; st<=X_DW;
                        end else case (rdo)
                            OP_HLT:  st<=X_HALT;
                            OP_IN:   st<=X_IN;
                            OP_OUT:  st<=X_OUT;
                            OP_ROR:  begin acc<={cy,acc[7:1]}; cy<=acc[0]; st<=X_F1; end
                            OP_OUTL: begin led_reg<=acc; st<=X_F1; end
                            OP_OUTT: begin tx_bit<=acc[0]; st<=X_F1; end
                            OP_TMRLO:begin tmr_term[7:0]<=acc; st<=X_F1; end
                            OP_TMRHI:begin tmr_term[15:8]<=acc; tmr<=TMR_SEED;
                                           tmr_en<=1'b1; st<=X_F1; end
                            OP_TSYNC:begin tmr_sync<=1'b1; tmr<=TMR_SEED;
                                           tmr_en<=1'b1; st<=X_F1; end
                            OP_EI:   begin ie<=1'b1; st<=X_F1; end
                            OP_DI:   begin ie<=1'b0; st<=X_F1; end
                            OP_RETI: begin pc<=ret_isr; acc<=acc_sh; acc_sh<=acc;
                                           cy<=cy_sh; cy_sh<=cy; in_isr<=1'b0; st<=X_F1; end
                            OP_PSHA: begin dspA_r<={dspA_r[7:0],acc}; st<=X_F1; end
                            OP_PSHB: begin dspB_r<={dspB_r[7:0],acc}; st<=X_F1; end
                            OP_PSHC: begin dspC_r<={dspC_r[23:0],acc}; st<=X_F1; end
                            OP_POPP: begin acc<=prod_rd[7:0]; prod_rd<={8'd0,prod_rd[31:8]}; st<=X_F1; end
                            default: st<=X_OA;
                        endcase
                    end
            X_OA:   st<=X_OB;
            X_OB:   begin opnd[7:0]<=rdo; pc<=pc+11'd1; st<=X_OC; end
            X_OC:   st<=X_OD;
            X_OD:   begin
                        opnd[15:8]<=rdo; pc<=pc+11'd1;
                        case (opc)
                            OP_LDI: begin acc<=opnd[7:0]; st<=X_F1; end
                            OP_JMP: begin pc<={rdo[2:0],opnd[7:0]};                st<=X_F1; end
                            OP_JZ:  begin if (acc==8'd0) pc<={rdo[2:0],opnd[7:0]}; st<=X_F1; end
                            OP_JNZ: begin if (acc!=8'd0) pc<={rdo[2:0],opnd[7:0]}; st<=X_F1; end
                            OP_JC:  begin if (cy)        pc<={rdo[2:0],opnd[7:0]}; st<=X_F1; end
                            OP_STA: st<=X_STA;
                            default: st<=X_M1;
                        endcase
                    end
            X_DW:   begin                                  // wait DSP48E1 pipeline, capture P
                        if (dcnt==3'd0) begin prod_rd<=dspP[31:0]; st<=X_F1; end
                        else dcnt<=dcnt-3'd1;
                    end
            X_M1:   st<=X_M2;
            X_M2:   begin
                        case (opc)
                            OP_LDA: acc <= rdo;
                            OP_ADD: {cy,acc} <= {1'b0,acc} + {1'b0,rdo};
                            OP_SUB: {cy,acc} <= {1'b0,acc} - {1'b0,rdo};
                            OP_ADC: {cy,acc} <= {1'b0,acc} + {1'b0,rdo} + cy;
                            OP_SBC: {cy,acc} <= {1'b0,acc} - {1'b0,rdo} - cy;
                            default: ;
                        endcase
                        st<=X_F1;
                    end
            X_STA:  begin waddr<=opnd[10:0]; wdata<=acc; we<=1'b1; st<=X_F1; end
            X_OUT:  if (tx_rdy && !tx_stb) begin tx_byte<=acc; tx_stb<=1'b1; st<=X_F1; end
            X_IN:   if (rx_valid) begin acc<=rx_data; st<=X_F1; end
            X_HALT: st<=C_IDLE;
            default: st<=C_IDLE;
            endcase
            // auto-reload down-counter; raise the interrupt flag on wrap.
            // Placed after the FSM so a tick that coincides with ISR-entry
            // (which clears tmr_if) still wins and is not lost.
            rx_prev <= rx_data[0];
            if (tmr_en) begin
                if (tmr_sync) begin
                    // hold the LFSR at SEED until the rx falling edge (start bit),
                    // then release exactly phased to the edge -> precise RX timing.
                    if (rx_fall) begin tmr <= TMR_SEED; tmr_sync <= 1'b0; end
                end else if (tmr == tmr_term) begin
                    tmr <= TMR_SEED; tmr_if <= 1'b1;
                end else begin
                    tmr <= {tmr[14:0], tmr_fb};     // LFSR shift (no carry chain)
                end
            end
        end
    end
endmodule
