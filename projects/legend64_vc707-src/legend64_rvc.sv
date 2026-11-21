// SPDX-License-Identifier: Apache-2.0
// legend64_rvc: expands a 16-bit RV64C instruction into its 32-bit equivalent.
// Reserved and illegal encodings set `illegal`; the caller then traps with the 16 raw bits.
module legend64_rvc (
    input  logic [15:0] c,
    output logic [31:0] x,
    output logic        illegal
);
  logic [4:0] rd, rs2, rdp, rs2p;
  assign rd   = c[11:7];
  assign rs2  = c[6:2];
  assign rdp  = {2'b01, c[9:7]};   // x8..x15
  assign rs2p = {2'b01, c[4:2]};

  logic [11:0] imm6;      // sign-extended 6-bit immediate
  logic [5:0]  shamt;
  logic [20:0] j_imm;
  logic [12:0] b_imm;
  assign imm6  = {{7{c[12]}}, c[6:2]};
  assign shamt = {c[12], c[6:2]};
  assign j_imm = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
  assign b_imm = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};

  // word and doubleword offsets
  logic [11:0] lw_off, ld_off, lwsp_off, ldsp_off, swsp_off, sdsp_off, addi4spn, addi16sp;
  assign lw_off   = {5'b0, c[5], c[12:10], c[6], 2'b00};
  assign ld_off   = {4'b0, c[6:5], c[12:10], 3'b000};
  assign lwsp_off = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
  assign ldsp_off = {3'b0, c[4:2], c[12], c[6:5], 3'b000};
  assign swsp_off = {4'b0, c[8:7], c[12:9], 2'b00};
  assign sdsp_off = {3'b0, c[9:7], c[12:10], 3'b000};
  assign addi4spn = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00};
  assign addi16sp = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};

  function automatic logic [31:0] i_type(input logic [11:0] imm, input logic [4:0] rs1, input logic [2:0] f3,
                                          input logic [4:0] d, input logic [6:0] op);
    return {imm, rs1, f3, d, op};
  endfunction
  function automatic logic [31:0] s_type(input logic [11:0] imm, input logic [4:0] s2, input logic [4:0] rs1,
                                          input logic [2:0] f3, input logic [6:0] op);
    return {imm[11:5], s2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic logic [31:0] r_type(input logic [6:0] f7, input logic [4:0] s2, input logic [4:0] rs1,
                                          input logic [2:0] f3, input logic [4:0] d, input logic [6:0] op);
    return {f7, s2, rs1, f3, d, op};
  endfunction

  localparam logic [6:0] OP_LOAD = 7'h03, OP_LOADFP = 7'h07, OP_IMM = 7'h13, OP_IMM32 = 7'h1b, OP_STORE = 7'h23,
                         OP_STOREFP = 7'h27, OP_OP = 7'h33, OP_LUI = 7'h37, OP_OP32 = 7'h3b, OP_BRANCH = 7'h63,
                         OP_JALR = 7'h67, OP_JAL = 7'h6f;

  always_comb begin
    x = 32'h0;
    illegal = 1'b0;
    unique case ({c[1:0], c[15:13]})
      // ---------------- quadrant 0
      5'b00_000: begin x = i_type(addi4spn, 5'd2, 3'b000, rs2p, OP_IMM); illegal = addi4spn == 12'h0; end
      5'b00_001: x = i_type(ld_off, rdp, 3'b011, rs2p, OP_LOADFP);                  // c.fld
      5'b00_010: x = i_type(lw_off, rdp, 3'b010, rs2p, OP_LOAD);                    // c.lw
      5'b00_011: x = i_type(ld_off, rdp, 3'b011, rs2p, OP_LOAD);                    // c.ld
      5'b00_101: x = s_type(ld_off, rs2p, rdp, 3'b011, OP_STOREFP);                 // c.fsd
      5'b00_110: x = s_type(lw_off, rs2p, rdp, 3'b010, OP_STORE);                   // c.sw
      5'b00_111: x = s_type(ld_off, rs2p, rdp, 3'b011, OP_STORE);                   // c.sd
      // ---------------- quadrant 1
      5'b01_000: x = i_type(imm6, rd, 3'b000, rd, OP_IMM);                          // c.addi, c.nop
      5'b01_001: begin x = i_type(imm6, rd, 3'b000, rd, OP_IMM32); illegal = rd == 5'd0; end   // c.addiw
      5'b01_010: x = i_type(imm6, 5'd0, 3'b000, rd, OP_IMM);                        // c.li
      5'b01_011: begin
        if (rd == 5'd2) x = i_type(addi16sp, 5'd2, 3'b000, 5'd2, OP_IMM);           // c.addi16sp
        else            x = {{15{c[12]}}, c[6:2], rd, OP_LUI};                      // c.lui
        illegal = {c[12], c[6:2]} == 6'b0;
      end
      5'b01_100: begin
        unique case (c[11:10])
          2'b00: x = i_type({6'b000000, shamt}, rdp, 3'b101, rdp, OP_IMM);          // c.srli
          2'b01: x = i_type({6'b010000, shamt}, rdp, 3'b101, rdp, OP_IMM);          // c.srai
          2'b10: x = i_type(imm6, rdp, 3'b111, rdp, OP_IMM);                        // c.andi
          default: begin
            unique case ({c[12], c[6:5]})
              3'b000: x = r_type(7'b0100000, rs2p, rdp, 3'b000, rdp, OP_OP);        // c.sub
              3'b001: x = r_type(7'b0000000, rs2p, rdp, 3'b100, rdp, OP_OP);        // c.xor
              3'b010: x = r_type(7'b0000000, rs2p, rdp, 3'b110, rdp, OP_OP);        // c.or
              3'b011: x = r_type(7'b0000000, rs2p, rdp, 3'b111, rdp, OP_OP);        // c.and
              3'b100: x = r_type(7'b0100000, rs2p, rdp, 3'b000, rdp, OP_OP32);      // c.subw
              3'b101: x = r_type(7'b0000000, rs2p, rdp, 3'b000, rdp, OP_OP32);      // c.addw
              default: illegal = 1'b1;
            endcase
          end
        endcase
      end
      5'b01_101: x = {j_imm[20], j_imm[10:1], j_imm[11], j_imm[19:12], 5'd0, OP_JAL};              // c.j
      5'b01_110: x = {b_imm[12], b_imm[10:5], 5'd0, rdp, 3'b000, b_imm[4:1], b_imm[11], OP_BRANCH}; // c.beqz
      5'b01_111: x = {b_imm[12], b_imm[10:5], 5'd0, rdp, 3'b001, b_imm[4:1], b_imm[11], OP_BRANCH}; // c.bnez
      // ---------------- quadrant 2
      5'b10_000: x = i_type({6'b000000, shamt}, rd, 3'b001, rd, OP_IMM);            // c.slli
      5'b10_001: x = i_type(ldsp_off, 5'd2, 3'b011, rd, OP_LOADFP);                 // c.fldsp
      5'b10_010: begin x = i_type(lwsp_off, 5'd2, 3'b010, rd, OP_LOAD); illegal = rd == 5'd0; end  // c.lwsp
      5'b10_011: begin x = i_type(ldsp_off, 5'd2, 3'b011, rd, OP_LOAD); illegal = rd == 5'd0; end  // c.ldsp
      5'b10_100: begin
        if (!c[12]) begin
          if (rs2 == 5'd0) begin x = i_type(12'h0, rd, 3'b000, 5'd0, OP_JALR); illegal = rd == 5'd0; end  // c.jr
          else x = r_type(7'b0, rs2, 5'd0, 3'b000, rd, OP_OP);                      // c.mv
        end else begin
          if (rs2 == 5'd0) begin
            if (rd == 5'd0) x = 32'h0010_0073;                                      // c.ebreak
            else x = i_type(12'h0, rd, 3'b000, 5'd1, OP_JALR);                      // c.jalr
          end else x = r_type(7'b0, rs2, rd, 3'b000, rd, OP_OP);                    // c.add
        end
      end
      5'b10_101: x = s_type(sdsp_off, rs2, 5'd2, 3'b011, OP_STOREFP);               // c.fsdsp
      5'b10_110: x = s_type(swsp_off, rs2, 5'd2, 3'b010, OP_STORE);                 // c.swsp
      5'b10_111: x = s_type(sdsp_off, rs2, 5'd2, 3'b011, OP_STORE);                 // c.sdsp
      default: illegal = 1'b1;
    endcase
  end
endmodule
