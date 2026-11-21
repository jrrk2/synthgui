// SPDX-License-Identifier: Apache-2.0
// legend64: an RV64GC core (RV64IMAFDC + Zicsr + Zifencei) with machine, supervisor and user
// modes and Sv39 virtual memory.
//
// Pipeline:
//   F  issue an instruction address (translated through the instruction TLB)
//   D  the fetched word joins a small parcel buffer; one instruction (16 or 32 bits, possibly
//      straddling two words) is taken from it, expanded if compressed, and its successor is
//      predicted: direct jumps, two-bit counters for conditional branches, a return-address
//      stack. A predicted redirect issues the new fetch in the same cycle.
//   X  read registers (one bypass from M), execute, resolve the prediction, take traps and
//      interrupts, translate and issue load/store requests. Everything that can trap or
//      redirect does so here: X is the single commit point.
//   M  load data returns; the integer or floating-point register file is written
//
// Multiply (2 cycles), divide (66), atomics and sequenced floating-point operations hold the
// instruction in X. A hardware page-table walker refills the two 8-entry TLBs through the data
// port. Accessed/dirty bits are not written by hardware: a clear A bit, or a store through a
// clear D bit, raises a page fault. ASIDs are not implemented (satp.ASID reads zero), so every
// satp write and every sfence.vma flushes both TLBs.
//
// Bus protocol, both ports: a request is accepted in a cycle where req && gnt. Read data comes
// back with rvalid one or more cycles later; one read may be outstanding per port. Writes are
// complete once granted. The instruction port reads aligned 32-bit words. The data bus is 64
// bits wide with byte enables; data sits in its natural byte lanes.
//
// Not implemented: PMP, debug mode, performance counters beyond cycle/instret/time. Misaligned loads and stores raise the
// address-misaligned exceptions. wfi is a no-op.

module legend64_tlb #(
    parameter int N = 8
) (
    input  logic        clk,
    input  logic        flush,
    input  logic [26:0] vpn,
    output logic        hit,
    output logic [43:0] ppn,       // already merged with the VPN for superpages
    output logic [4:0]  perm,      // {D, U, X, W, R}
    input  logic        fill,
    input  logic [26:0] fill_vpn,
    input  logic [43:0] fill_ppn,
    input  logic [1:0]  fill_level,
    input  logic [4:0]  fill_perm
);
  logic [N-1:0]       valid = '0;
  logic [26:0]        e_vpn  [N];
  logic [43:0]        e_ppn  [N];
  logic [1:0]         e_lvl  [N];
  logic [4:0]         e_perm [N];
  logic [$clog2(N)-1:0] next = '0;

  always_comb begin
    hit = 1'b0; ppn = '0; perm = '0;
    for (int i = 0; i < N; i++) begin
      if (valid[i] && e_vpn[i][26:18] == vpn[26:18] &&
          (e_lvl[i] == 2'd2 || e_vpn[i][17:9] == vpn[17:9]) &&
          (e_lvl[i] != 2'd0 || e_vpn[i][8:0] == vpn[8:0])) begin
        hit  = 1'b1;
        perm = e_perm[i];
        ppn  = {e_ppn[i][43:18],
                e_lvl[i] == 2'd2 ? vpn[17:9] : e_ppn[i][17:9],
                e_lvl[i] != 2'd0 ? vpn[8:0]  : e_ppn[i][8:0]};
      end
    end
  end

  // flush is also the reset: it clears the entries and the replacement pointer with the valid
  // bits, so that no register here is ever without a defined value
  always_ff @(posedge clk) begin
    if (flush) begin
      valid <= '0;
      next  <= '0;
      for (int i = 0; i < N; i++) begin
        e_vpn[i] <= '0; e_ppn[i] <= '0; e_lvl[i] <= '0; e_perm[i] <= '0;
      end
    end else if (fill) begin
      valid[next]  <= 1'b1;
      e_vpn[next]  <= fill_vpn;
      e_ppn[next]  <= fill_ppn;
      e_lvl[next]  <= fill_level;
      e_perm[next] <= fill_perm;
      next         <= next + 1'b1;
    end
  end
endmodule

module legend64 #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000,
    parameter int unsigned BHT_BITS = 9,
    parameter int          TLB_ENTRIES = 8      // each of the two TLBs; a power of two
) (
    input  logic        clk,
    input  logic        rst_n,

    output logic        imem_req,
    output logic [63:0] imem_addr,
    input  logic        imem_gnt,
    input  logic        imem_rvalid,
    input  logic [31:0] imem_rdata,

    output logic        dmem_req,
    output logic        dmem_we,
    output logic [63:0] dmem_addr,
    output logic [63:0] dmem_wdata,
    output logic [7:0]  dmem_be,
    input  logic        dmem_gnt,
    input  logic        dmem_rvalid,
    input  logic [63:0] dmem_rdata,

    input  logic        irq_m_ext,
    input  logic        irq_m_timer,
    input  logic        irq_m_soft,
    input  logic        irq_s_ext,
    input  logic [63:0] time_i,       // platform timer (mtime), readable as the time CSR

    // one pulse per retired instruction, in program order
    output logic        tr_valid,
    output logic [63:0] tr_pc,
    output logic [31:0] tr_insn,   // as fetched: 16 significant bits for a compressed instruction
    output logic        tr_wen,    // integer register written
    output logic        tr_fwen,   // floating-point register written
    output logic [4:0]  tr_rd,
    output logic [63:0] tr_wdata,
    // one pulse per trap taken (exception or interrupt)
    output logic        tr_trap,
    output logic        tr_trap_late,   // an older instruction is still to be reported: this trap follows it
    output logic [63:0] tr_cause,
    output logic [63:0] tr_epc,
    output logic [63:0] tr_tval
);
  localparam logic [1:0] PRV_U = 2'b00, PRV_S = 2'b01, PRV_M = 2'b11;

  // ------------------------------------------------------------------ state
  logic [63:0] f_pc;                 // next parcel to fetch
  logic        f_halt;               // a fetch fault is queued; wait for the redirect
  logic        pend_fetch, pend_kill, pend_fault, pend_skip;
  logic [63:0] buf_data;             // up to four 16-bit parcels
  logic [3:0]  buf_flt;
  logic [2:0]  buf_cnt;
  logic [63:0] buf_pc;               // address of the first parcel in (or next to enter) the buffer

  logic        ir_valid, ir_c;
  logic [1:0]  ir_flt;               // 1: page fault on the first parcel, 2: on the second
  logic [31:0] ir, ir_raw;
  logic [63:0] ir_pc, ir_pnpc;

  typedef enum logic [2:0] {X_IDLE, X_MUL, X_DIV, X_AMO_WAIT, X_AMO_ST} xstate_e;
  xstate_e x_state;

  logic        m_valid, m_wen, m_fwen, m_load, m_box;
  logic [4:0]  m_rd;
  logic [63:0] m_val, m_pc;
  logic [31:0] m_insn;
  logic [2:0]  m_f3, m_off;

  logic [63:0] regs  [32];
  logic [63:0] fregs [32];

  // CSR state
  logic [1:0]  priv;
  logic        mstatus_sie, mstatus_mie, mstatus_spie, mstatus_mpie, mstatus_spp, mstatus_mprv,
               mstatus_sum, mstatus_mxr, mstatus_tvm, mstatus_tw, mstatus_tsr;
  logic [1:0]  mstatus_mpp, mstatus_fs;
  logic [63:0] mtvec, mscratch, mepc, mcause, mtval, mcycle, minstret;
  logic [63:0] stvec, sscratch, sepc, scause, stval;
  logic [15:0] medeleg;
  logic        mideleg_s, mideleg_t, mideleg_e;        // bits 1, 5, 9
  logic        mie_ssie, mie_msie, mie_stie, mie_mtie, mie_seie, mie_meie;
  logic        mip_ssip, mip_stip, mip_seip;
  logic [2:0]  mcounteren, scounteren;
  logic        satp_sv39;
  logic [43:0] satp_ppn;
  logic [4:0]  fflags;
  logic [2:0]  frm;
  logic        resv_valid;
  logic [63:0] resv_addr;

  // ------------------------------------------------------------------ X: decode
  logic [6:0] opcode;
  logic [2:0] f3;
  logic [6:0] f7;
  logic [4:0] rd, rs1, rs2, rs3;
  assign opcode = ir[6:0];
  assign f3 = ir[14:12];
  assign f7 = ir[31:25];
  assign rd = ir[11:7];
  assign rs1 = ir[19:15];
  assign rs2 = ir[24:20];
  assign rs3 = ir[31:27];

  logic op_lui, op_auipc, op_jal, op_jalr, op_branch, op_load, op_store, op_opimm, op_opimm32, op_op,
        op_op32, op_miscmem, op_system, op_amo, op_loadfp, op_storefp, op_fma, op_fp;
  assign op_lui     = opcode == 7'b0110111;
  assign op_auipc   = opcode == 7'b0010111;
  assign op_jal     = opcode == 7'b1101111;
  assign op_jalr    = opcode == 7'b1100111;
  assign op_branch  = opcode == 7'b1100011;
  assign op_load    = opcode == 7'b0000011;
  assign op_store   = opcode == 7'b0100011;
  assign op_opimm   = opcode == 7'b0010011;
  assign op_opimm32 = opcode == 7'b0011011;
  assign op_op      = opcode == 7'b0110011;
  assign op_op32    = opcode == 7'b0111011;
  assign op_miscmem = opcode == 7'b0001111;
  assign op_system  = opcode == 7'b1110011;
  assign op_amo     = opcode == 7'b0101111;
  assign op_loadfp  = opcode == 7'b0000111;
  assign op_storefp = opcode == 7'b0100111;
  assign op_fma     = opcode[6:4] == 3'b100 && opcode[1:0] == 2'b11;
  assign op_fp      = opcode == 7'b1010011;

  logic is_muldiv, is_mul, is_div, is_w, is_alu;
  assign is_muldiv = (op_op || op_op32) && f7 == 7'b0000001;
  assign is_mul    = is_muldiv && !f3[2];
  assign is_div    = is_muldiv && f3[2];
  assign is_w      = op_op32 || op_opimm32;
  assign is_alu    = (op_op || op_op32) && !is_muldiv || op_opimm || op_opimm32;

  logic is_csr, is_ecall, is_ebreak, is_mret, is_sret, is_wfi, is_sfence, is_lr, is_sc, is_amo_rmw;
  assign is_csr     = op_system && f3[1:0] != 2'b00;
  assign is_ecall   = ir == 32'h0000_0073;
  assign is_ebreak  = ir == 32'h0010_0073;
  assign is_mret    = ir == 32'h3020_0073;
  assign is_sret    = ir == 32'h1020_0073;
  assign is_wfi     = ir == 32'h1050_0073;
  assign is_sfence  = op_system && f3 == 3'b000 && f7 == 7'b0001001 && rd == 5'd0;
  assign is_lr      = op_amo && ir[31:27] == 5'b00010;
  assign is_sc      = op_amo && ir[31:27] == 5'b00011;
  assign is_amo_rmw = op_amo && !is_lr && !is_sc;

  // floating-point classification
  logic fp_any, fp_dest_int, fp_use_frm, fp_seq_legal, fs_on, rm_ok, fp_legal;
  logic [2:0] rm_eff;
  assign fs_on  = mstatus_fs != 2'b00;
  assign rm_eff = f3 == 3'b111 ? frm : f3;
  assign rm_ok  = rm_eff <= 3'd4;
  assign fp_any = op_fma || op_fp;
  assign fp_dest_int = op_fp && (ir[31:27] == 5'b10100 || ir[31:27] == 5'b11000 || ir[31:27] == 5'b11100);
  always_comb begin
    fp_use_frm   = 1'b0;
    fp_seq_legal = 1'b0;
    if (op_fma) begin
      fp_use_frm = 1'b1; fp_seq_legal = !ir[26];
    end else if (op_fp && !ir[26]) begin
      unique case (ir[31:27])
        5'b00000, 5'b00001, 5'b00010, 5'b00011: begin fp_use_frm = 1'b1; fp_seq_legal = 1'b1; end
        5'b01011: begin fp_use_frm = 1'b1; fp_seq_legal = rs2 == 5'd0; end
        5'b00100: fp_seq_legal = f3 <= 3'd2;
        5'b00101: fp_seq_legal = f3 <= 3'd1;
        5'b01000: begin fp_use_frm = 1'b1; fp_seq_legal = rs2 == {4'b0, !ir[25]}; end
        5'b10100: fp_seq_legal = f3 <= 3'd2;
        5'b11000, 5'b11010: begin fp_use_frm = 1'b1; fp_seq_legal = rs2 <= 5'd3; end
        5'b11100: fp_seq_legal = rs2 == 5'd0 && f3 <= 3'd1;
        5'b11110: fp_seq_legal = rs2 == 5'd0 && f3 == 3'd0;
        default: ;
      endcase
    end
  end
  assign fp_legal = fp_seq_legal && fs_on && (!fp_use_frm || rm_ok);

  // ------------------------------------------------------------------ X: operands
  logic [63:0] rs1v, rs2v, fa, fb, fc;
  logic        m_fwd_x, m_fwd_f, x_hazard;
  assign m_fwd_x = m_valid && m_wen && !m_load;
  assign m_fwd_f = m_valid && m_fwen && !m_load;
  assign rs1v = rs1 == 5'd0 ? 64'd0 : (m_fwd_x && m_rd == rs1) ? m_val : regs[rs1];
  assign rs2v = rs2 == 5'd0 ? 64'd0 : (m_fwd_x && m_rd == rs2) ? m_val : regs[rs2];
  assign fa = (m_fwd_f && m_rd == rs1) ? m_val : fregs[rs1];
  assign fb = (m_fwd_f && m_rd == rs2) ? m_val : fregs[rs2];
  assign fc = (m_fwd_f && m_rd == rs3) ? m_val : fregs[rs3];
  // a load still in M has no value to bypass: wait for it to reach the register file
  assign x_hazard = m_valid && m_load && (m_wen || m_fwen) && (m_rd == rs1 || m_rd == rs2 || m_rd == rs3);

  logic [63:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  assign imm_i = {{52{ir[31]}}, ir[31:20]};
  assign imm_s = {{52{ir[31]}}, ir[31:25], ir[11:7]};
  assign imm_b = {{51{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
  assign imm_u = {{32{ir[31]}}, ir[31:12], 12'b0};
  assign imm_j = {{43{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

  // ------------------------------------------------------------------ X: integer ALU
  logic        alu_imm, alu_sub, alu_arith;
  logic [63:0] alu_b, alu_add, sh_in, sh_l, sh_r, alu_raw, alu_out;
  logic [5:0]  shamt;
  assign alu_imm   = op_opimm || op_opimm32;
  assign alu_b     = alu_imm ? imm_i : rs2v;
  assign alu_sub   = !alu_imm && ir[30];
  assign alu_arith = ir[30];
  assign alu_add   = alu_sub ? rs1v - rs2v : rs1v + alu_b;
  assign shamt     = is_w ? {1'b0, alu_b[4:0]} : alu_b[5:0];
  assign sh_in     = !is_w ? rs1v : alu_arith ? {{32{rs1v[31]}}, rs1v[31:0]} : {32'b0, rs1v[31:0]};
  assign sh_l      = rs1v << shamt;
  assign sh_r      = 64'($signed({alu_arith & sh_in[63], sh_in}) >>> shamt);
  always_comb begin
    unique case (f3)
      3'b000: alu_raw = alu_add;
      3'b001: alu_raw = sh_l;
      3'b010: alu_raw = {63'b0, $signed(rs1v) < $signed(alu_b)};
      3'b011: alu_raw = {63'b0, rs1v < alu_b};
      3'b100: alu_raw = rs1v ^ alu_b;
      3'b101: alu_raw = sh_r;
      3'b110: alu_raw = rs1v | alu_b;
      default: alu_raw = rs1v & alu_b;
    endcase
  end
  assign alu_out = is_w ? {{32{alu_raw[31]}}, alu_raw[31:0]} : alu_raw;

  // ------------------------------------------------------------------ X: control flow
  logic br_eq, br_lt, br_ltu, br_taken;
  assign br_eq  = rs1v == rs2v;
  assign br_lt  = $signed(rs1v) < $signed(rs2v);
  assign br_ltu = rs1v < rs2v;
  always_comb begin
    unique case (f3)
      3'b000: br_taken = br_eq;
      3'b001: br_taken = !br_eq;
      3'b100: br_taken = br_lt;
      3'b101: br_taken = !br_lt;
      3'b110: br_taken = br_ltu;
      default: br_taken = !br_ltu;
    endcase
  end
  logic [63:0] pc_next, pc_target, jalr_sum, x_npc;
  assign pc_next   = ir_pc + (ir_c ? 64'd2 : 64'd4);
  assign pc_target = ir_pc + (op_jal ? imm_j : imm_b);
  assign jalr_sum  = rs1v + imm_i;
  assign x_npc = op_jalr ? {jalr_sum[63:1], 1'b0} :
                 (op_jal || (op_branch && br_taken)) ? pc_target :
                 is_mret ? mepc : is_sret ? sepc : pc_next;

  // ------------------------------------------------------------------ X: memory access
  logic [63:0] ea, st_src, amo_data, amo_paddr;
  logic        ea_misaligned;
  assign ea = op_amo ? rs1v : rs1v + ((op_store || op_storefp) ? imm_s : imm_i);
  always_comb begin
    unique case (f3[1:0])
      2'b00: ea_misaligned = 1'b0;
      2'b01: ea_misaligned = ea[0];
      2'b10: ea_misaligned = |ea[1:0];
      default: ea_misaligned = |ea[2:0];
    endcase
  end

  logic [63:0] amo_a, amo_b, amo_new;
  always_comb begin
    amo_a = f3[0] ? amo_data : {{32{amo_data[31]}}, amo_data[31:0]};
    amo_b = f3[0] ? rs2v : {{32{rs2v[31]}}, rs2v[31:0]};
    unique case (ir[31:27])
      5'b00001: amo_new = amo_b;
      5'b00000: amo_new = amo_a + amo_b;
      5'b00100: amo_new = amo_a ^ amo_b;
      5'b01100: amo_new = amo_a & amo_b;
      5'b01000: amo_new = amo_a | amo_b;
      5'b10000: amo_new = $signed(amo_a) < $signed(amo_b) ? amo_a : amo_b;
      5'b10100: amo_new = $signed(amo_a) < $signed(amo_b) ? amo_b : amo_a;
      5'b11000: amo_new = (f3[0] ? amo_a < amo_b : amo_a[31:0] < amo_b[31:0]) ? amo_a : amo_b;
      default:  amo_new = (f3[0] ? amo_a < amo_b : amo_a[31:0] < amo_b[31:0]) ? amo_b : amo_a;
    endcase
  end
  assign st_src = op_storefp ? fb : (x_state == X_AMO_ST) ? amo_new : rs2v;

  logic [7:0] st_mask;
  always_comb begin
    unique case (f3[1:0])
      2'b00: st_mask = 8'h01;
      2'b01: st_mask = 8'h03;
      2'b10: st_mask = 8'h0f;
      default: st_mask = 8'hff;
    endcase
  end

  // ------------------------------------------------------------------ data address translation
  logic [1:0]  eff_priv;
  logic        d_xlate, d_noncanon, dtlb_hit, d_perm_ok, d_is_store, d_u_ok, d_ptw_fault, tlb_flush;
  logic [43:0] dtlb_ppn;
  logic [4:0]  dtlb_perm;
  logic [63:0] d_paddr;
  logic        ptw_fill_d, ptw_fill_i;
  logic [26:0] ptw_vpn;
  logic [43:0] ptw_fill_ppn;
  logic [1:0]  ptw_level;
  logic [4:0]  ptw_fill_perm;

  assign eff_priv   = (mstatus_mprv && priv == PRV_M) ? mstatus_mpp : priv;
  assign d_xlate    = satp_sv39 && eff_priv != PRV_M;
  assign d_noncanon = ea[63:39] != {25{ea[38]}};
  assign d_is_store = op_store || op_storefp || is_sc || is_amo_rmw;
  assign d_u_ok     = eff_priv == PRV_U ? dtlb_perm[3] : (!dtlb_perm[3] || mstatus_sum);
  assign d_perm_ok  = d_u_ok && (d_is_store ? (dtlb_perm[1] && dtlb_perm[4])
                                            : (dtlb_perm[0] || (mstatus_mxr && dtlb_perm[2])));
  assign d_paddr    = d_xlate ? {8'b0, dtlb_ppn, ea[11:0]} : ea;

  legend64_tlb #(.N(TLB_ENTRIES)) u_dtlb (
      .clk, .flush(tlb_flush), .vpn(ea[38:12]), .hit(dtlb_hit), .ppn(dtlb_ppn), .perm(dtlb_perm),
      .fill(ptw_fill_d), .fill_vpn(ptw_vpn), .fill_ppn(ptw_fill_ppn), .fill_level(ptw_level), .fill_perm(ptw_fill_perm)
  );

  // ------------------------------------------------------------------ X: multiply / divide
  logic [127:0] mul_p;
  logic         mul_sa, mul_sb;
  logic signed [129:0] mul_full;
  assign mul_sa = rs1v[63] && (f3[1:0] == 2'b01 || f3[1:0] == 2'b10);
  assign mul_sb = rs2v[63] && f3[1:0] == 2'b01;
  assign mul_full = $signed({mul_sa, rs1v}) * $signed({mul_sb, rs2v});

  logic [63:0] div_rem, div_quo, div_den, div_a, div_b, div_result;
  logic [6:0]  div_cnt;
  logic        div_neg_q, div_neg_r, div_signed;
  logic [64:0] div_shift;
  logic [65:0] div_sub;
  assign div_signed = !f3[0];
  assign div_a = !op_op32 ? rs1v : div_signed ? {{32{rs1v[31]}}, rs1v[31:0]} : {32'b0, rs1v[31:0]};
  assign div_b = !op_op32 ? rs2v : div_signed ? {{32{rs2v[31]}}, rs2v[31:0]} : {32'b0, rs2v[31:0]};
  assign div_shift = {div_rem, div_quo[63]};
  assign div_sub = {1'b0, div_shift} - {2'b0, div_den};
  assign div_result = f3[1] ? (div_neg_r ? -div_rem : div_rem) : (div_neg_q ? -div_quo : div_quo);

  // ------------------------------------------------------------------ X: CSRs
  logic [11:0] csr_addr;
  logic [63:0] csr_rdata, csr_wdata, csr_src, mstatus_r, sstatus_r, mip_r, mie_r, mideleg_r, satp_r;
  logic        csr_exists, csr_write, csr_legal;
  assign csr_addr  = ir[31:20];
  assign mstatus_r = {mstatus_fs == 2'b11, 27'b0, 2'b10, 2'b10, 9'b0, mstatus_tsr, mstatus_tw, mstatus_tvm,
                      mstatus_mxr, mstatus_sum, mstatus_mprv, 2'b0, mstatus_fs, mstatus_mpp, 2'b0,
                      mstatus_spp, mstatus_mpie, 1'b0, mstatus_spie, 1'b0, mstatus_mie, 1'b0, mstatus_sie, 1'b0};
  assign sstatus_r = mstatus_r & 64'h8000_0003_000d_e122;
  assign mip_r     = {52'b0, irq_m_ext, 1'b0, mip_seip | irq_s_ext, 1'b0, irq_m_timer, 1'b0, mip_stip, 1'b0,
                      irq_m_soft, 1'b0, mip_ssip, 1'b0};
  assign mie_r     = {52'b0, mie_meie, 1'b0, mie_seie, 1'b0, mie_mtie, 1'b0, mie_stie, 1'b0, mie_msie, 1'b0, mie_ssie, 1'b0};
  assign mideleg_r = {54'b0, mideleg_e, 3'b0, mideleg_t, 3'b0, mideleg_s, 1'b0};
  assign satp_r    = {satp_sv39, 3'b0, 16'b0, satp_ppn};
  always_comb begin
    csr_exists = 1'b1;
    csr_rdata  = '0;
    unique case (csr_addr)
      12'h001: begin csr_rdata = {59'b0, fflags};      csr_exists = fs_on; end
      12'h002: begin csr_rdata = {61'b0, frm};         csr_exists = fs_on; end
      12'h003: begin csr_rdata = {56'b0, frm, fflags}; csr_exists = fs_on; end
      12'h100: csr_rdata = sstatus_r;
      12'h104: csr_rdata = mie_r & mideleg_r;
      12'h105: csr_rdata = stvec;
      12'h106: csr_rdata = {61'b0, scounteren};
      12'h10a: csr_rdata = '0;                         // senvcfg
      12'h140: csr_rdata = sscratch;
      12'h141: csr_rdata = sepc;
      12'h142: csr_rdata = scause;
      12'h143: csr_rdata = stval;
      12'h144: csr_rdata = mip_r & mideleg_r;
      12'h180: begin csr_rdata = satp_r; csr_exists = !(priv == PRV_S && mstatus_tvm); end
      12'h300: csr_rdata = mstatus_r;
      12'h301: csr_rdata = 64'h8000_0000_0014_112d;   // RV64 ACDFIMSU
      12'h302: csr_rdata = {48'b0, medeleg};
      12'h303: csr_rdata = mideleg_r;
      12'h304: csr_rdata = mie_r;
      12'h305: csr_rdata = mtvec;
      12'h306: csr_rdata = {61'b0, mcounteren};
      12'h30a: csr_rdata = '0;                         // menvcfg
      12'h320: csr_rdata = '0;                         // mcountinhibit
      12'h340: csr_rdata = mscratch;
      12'h341: csr_rdata = mepc;
      12'h342: csr_rdata = mcause;
      12'h343: csr_rdata = mtval;
      12'h344: csr_rdata = mip_r;
      12'hb00: csr_rdata = mcycle;
      12'hb02: csr_rdata = minstret;
      12'hc00: begin csr_rdata = mcycle;   csr_exists = priv == PRV_M || (mcounteren[0] && (priv == PRV_S || scounteren[0])); end
      12'hc01: begin csr_rdata = time_i;   csr_exists = priv == PRV_M || (mcounteren[1] && (priv == PRV_S || scounteren[1])); end
      12'hc02: begin csr_rdata = minstret; csr_exists = priv == PRV_M || (mcounteren[2] && (priv == PRV_S || scounteren[2])); end
      12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: csr_rdata = '0;
      12'h7a0, 12'h7a1, 12'h7a2, 12'h7a3: csr_rdata = '0;   // no debug triggers: tdata1 type reads 0
      default: begin
        // hardware performance counters and their event selectors read as zero
        csr_exists = (csr_addr >= 12'hb03 && csr_addr <= 12'hb1f) || (csr_addr >= 12'h323 && csr_addr <= 12'h33f);
      end
    endcase
  end
  assign csr_src   = f3[2] ? {59'b0, rs1} : rs1v;
  assign csr_write = f3[1:0] == 2'b01 || rs1 != 5'd0;
  assign csr_wdata = f3[1:0] == 2'b01 ? csr_src : f3[1:0] == 2'b10 ? csr_rdata | csr_src : csr_rdata & ~csr_src;
  assign csr_legal = csr_exists && priv >= csr_addr[9:8] && !(csr_write && csr_addr[11:10] == 2'b11);

  // ------------------------------------------------------------------ X: legality
  logic legal;
  always_comb begin
    legal = 1'b0;
    if (ir[1:0] == 2'b11) begin
      if (op_lui || op_auipc || op_jal) legal = 1'b1;
      if (op_jalr) legal = f3 == 3'b000;
      if (op_branch) legal = f3[2:1] != 2'b01;
      if (op_load) legal = f3 != 3'b111;
      if (op_store) legal = !f3[2];
      if (op_opimm) legal = f3 == 3'b001 ? ir[31:26] == 6'b0 : f3 == 3'b101 ? (ir[31:26] == 6'b0 || ir[31:26] == 6'b010000) : 1'b1;
      if (op_opimm32) legal = f3 == 3'b000 || (f3 == 3'b001 && f7 == 7'b0) || (f3 == 3'b101 && (f7 == 7'b0 || f7 == 7'b0100000));
      if (op_op) legal = f7 == 7'b0 || f7 == 7'b0000001 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101));
      if (op_op32) legal = (f7 == 7'b0 && (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b101)) ||
                           (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101)) ||
                           (f7 == 7'b0000001 && (f3 == 3'b000 || f3[2]));
      if (op_miscmem) legal = f3 == 3'b000 || f3 == 3'b001;
      if (op_system) begin
        if (is_csr)         legal = csr_legal;
        else if (is_mret)   legal = priv == PRV_M;
        else if (is_sret)   legal = priv == PRV_M || (priv == PRV_S && !mstatus_tsr);
        else if (is_wfi)    legal = priv == PRV_M || (priv == PRV_S && !mstatus_tw);
        else if (is_sfence) legal = priv == PRV_M || (priv == PRV_S && !mstatus_tvm);
        else                legal = is_ecall || is_ebreak;
      end
      if (op_amo) begin
        legal = f3[2:1] == 2'b01;
        unique case (ir[31:27])
          5'b00010: legal &= rs2 == 5'd0;
          5'b00011, 5'b00001, 5'b00000, 5'b00100, 5'b01100, 5'b01000, 5'b10000, 5'b10100, 5'b11000, 5'b11100: ;
          default: legal = 1'b0;
        endcase
      end
      if (op_loadfp || op_storefp) legal = fs_on && f3[2:1] == 2'b01;
      if (fp_any) legal = fp_legal;
    end
  end

  // ------------------------------------------------------------------ FPU
  logic        fpu_start, fpu_busy, fpu_done, x_done;
  logic [63:0] fpu_result;
  logic [4:0]  fpu_flags;
  legend64_fpu u_fpu (
      .clk, .rst_n,
      .start(fpu_start), .accept(x_done), .insn(ir),
      .a_raw(fa), .b_raw(fb), .c_raw(fc), .x_in(rs1v), .rm(rm_eff),
      .busy(fpu_busy), .done(fpu_done), .result(fpu_result), .flags(fpu_flags)
  );

  // ------------------------------------------------------------------ X: interrupts and traps
  logic        x_exec, x_first, m_free, irq_take, x_exc, x_trap, x_redirect, trap_to_s;
  logic [63:0] irq_pend, irq_m, irq_s, trap_cause, trap_tval, trap_target;
  logic [3:0]  irq_code;
  assign m_free  = !m_valid || !m_load || dmem_rvalid;
  assign x_exec  = ir_valid && !x_hazard;
  assign x_first = x_exec && x_state == X_IDLE && !fpu_busy;   // nothing started yet for this instruction

  assign irq_pend = mip_r & mie_r;
  assign irq_m    = irq_pend & ~mideleg_r;
  assign irq_s    = irq_pend & mideleg_r;
  logic irq_m_en, irq_s_en;
  assign irq_m_en = |irq_m && (priv != PRV_M || mstatus_mie);
  assign irq_s_en = |irq_s && (priv == PRV_U || (priv == PRV_S && mstatus_sie));
  assign irq_take = x_first && (irq_m_en || irq_s_en);
  always_comb begin
    logic [63:0] v;
    v = irq_m_en ? irq_m : irq_s;
    irq_code = v[11] ? 4'd11 : v[3] ? 4'd3 : v[7] ? 4'd7 : v[9] ? 4'd9 : v[1] ? 4'd1 : 4'd5;
  end

  logic x_mem_any, x_mem_use, exc_misaligned, exc_dpf, x_ok;
  assign x_mem_any = op_load || op_store || op_loadfp || op_storefp || op_amo;
  // a store-conditional without a reservation fails without touching memory
  assign x_mem_use = x_mem_any && !(is_sc && !resv_valid);
  assign x_ok      = ir_flt == 2'd0 && legal;
  assign exc_misaligned = x_ok && x_mem_any && ea_misaligned;
  assign exc_dpf   = x_ok && x_mem_use && !ea_misaligned && d_xlate &&
                     (d_noncanon || (dtlb_hit && !d_perm_ok) || d_ptw_fault);
  assign x_exc  = x_first && !irq_take && (ir_flt != 2'd0 || !legal || is_ecall || is_ebreak || exc_misaligned || exc_dpf);
  assign x_trap = irq_take || x_exc;
  always_comb begin
    trap_tval = '0;
    if (irq_take) begin
      trap_cause = {1'b1, 59'b0, irq_code};
    end else if (ir_flt != 2'd0) begin
      trap_cause = 64'd12; trap_tval = ir_flt == 2'd2 ? ir_pc + 64'd2 : ir_pc;
    end else if (!legal) begin
      trap_cause = 64'd2;  trap_tval = {32'b0, ir_raw};
    end else if (is_ecall) begin
      trap_cause = priv == PRV_M ? 64'd11 : priv == PRV_S ? 64'd9 : 64'd8;
    end else if (is_ebreak) begin
      trap_cause = 64'd3;  trap_tval = ir_pc;
    end else if (exc_misaligned) begin
      trap_cause = (d_is_store) ? 64'd6 : 64'd4;  trap_tval = ea;
    end else begin
      trap_cause = (d_is_store) ? 64'd15 : 64'd13; trap_tval = ea;
    end
    // delegation: interrupts by mideleg (only S-level interrupts can be pending there), exceptions by medeleg
    trap_to_s = priv != PRV_M && (irq_take ? !irq_m_en : medeleg[trap_cause[3:0]]);
    if (trap_to_s) trap_target = {stvec[63:2], 2'b00} + ((stvec[0] && irq_take) ? {58'b0, trap_cause[3:0], 2'b00} : 64'd0);
    else           trap_target = {mtvec[63:2], 2'b00} + ((mtvec[0] && irq_take) ? {58'b0, trap_cause[3:0], 2'b00} : 64'd0);
  end

  // ------------------------------------------------------------------ page-table walker
  typedef enum logic [1:0] {P_IDLE, P_REQ, P_WAIT} pstate_e;
  pstate_e     ptw_state;
  logic        ptw_for_i, ptw_kill, ptw_busy, ptw_start_d, ptw_start_i, iptw_want;
  logic [43:0] ptw_a;
  logic [63:0] pte;
  logic        pte_bad, pte_leaf, pte_fault, iptw_fault;
  logic [26:0] iptw_fault_vpn, fetch_vpn;
  assign ptw_busy = ptw_state != P_IDLE;
  assign pte      = dmem_rdata;
  assign pte_leaf = pte[1] || pte[3];
  assign pte_bad  = !pte[0] || (!pte[1] && pte[2]) || pte[63:54] != '0;
  always_comb begin
    pte_fault = pte_bad;
    if (!pte_bad && pte_leaf) begin
      // misaligned superpage, or accessed bit clear (hardware does not set it)
      if ((ptw_level == 2'd2 && pte[27:10] != '0) || (ptw_level == 2'd1 && pte[18:10] != '0) || !pte[6]) pte_fault = 1'b1;
    end else if (!pte_bad && ptw_level == 2'd0) pte_fault = 1'b1;
  end
  assign ptw_fill_ppn  = pte[53:10];
  assign ptw_fill_perm = {pte[7], pte[4], pte[3], pte[2], pte[1]};
  assign ptw_fill_d    = ptw_state == P_WAIT && dmem_rvalid && !pte_fault && pte_leaf && !ptw_for_i;
  assign ptw_fill_i    = ptw_state == P_WAIT && dmem_rvalid && !pte_fault && pte_leaf && ptw_for_i;

  // ------------------------------------------------------------------ X: sequencing
  logic x_rd_want, x_wr_want, x_rd_req, x_wr_req, sc_ok, x_plain, x_xlate_ok;
  assign x_xlate_ok = !d_xlate || (dtlb_hit && d_perm_ok && !d_noncanon);
  assign x_plain    = x_first && !x_trap && m_free && !ptw_busy && x_xlate_ok;
  assign sc_ok      = resv_valid && resv_addr == d_paddr;
  assign x_rd_want  = op_load || op_loadfp || is_lr || is_amo_rmw;
  assign x_wr_want  = op_store || op_storefp || (is_sc && sc_ok);
  assign x_rd_req   = x_plain && x_rd_want;
  assign x_wr_req   = (x_plain && x_wr_want) || (x_state == X_AMO_ST && m_free && !ptw_busy);

  // a data access that misses the TLB starts a walk; the instruction then retries
  assign ptw_start_d = x_first && !irq_take && x_ok && x_mem_use && !ea_misaligned && d_xlate && !d_noncanon &&
                       !dtlb_hit && !d_ptw_fault && m_free && !ptw_busy;
  assign ptw_start_i = iptw_want && !ptw_start_d && !ptw_busy && m_free && x_state == X_IDLE &&
                       !(x_rd_req || x_wr_req);

  assign dmem_req   = ptw_state == P_REQ || x_rd_req || x_wr_req;
  assign dmem_we    = ptw_state != P_REQ && x_wr_req;
  assign dmem_addr  = ptw_state == P_REQ ? {8'b0, ptw_a, ptw_level == 2'd2 ? ptw_vpn[26:18] : ptw_level == 2'd1 ? ptw_vpn[17:9] : ptw_vpn[8:0], 3'b000}
                    : x_state == X_AMO_ST ? amo_paddr : d_paddr;
  assign dmem_wdata = st_src << {ea[2:0], 3'b000};
  assign dmem_be    = dmem_we ? st_mask << ea[2:0] : 8'h00;

  logic x_single, x_refetch;
  assign x_single  = op_lui || op_auipc || op_jal || op_jalr || op_branch || is_alu || op_miscmem || op_system;
  assign fpu_start = x_exec && x_state == X_IDLE && !x_trap && fp_any && x_ok;
  always_comb begin
    x_done = 1'b0;
    if (x_exec && m_free && !x_trap) begin
      unique case (x_state)
        X_IDLE: begin
          if (fp_any) x_done = fpu_start && fpu_done;
          else if (fpu_busy) x_done = 1'b0;
          else if (x_single) x_done = 1'b1;
          else if (is_sc && !sc_ok) x_done = !resv_valid || (x_plain);   // fails: needs no bus cycle
          else if (x_rd_want && !is_amo_rmw) x_done = x_rd_req && dmem_gnt;
          else if (x_wr_want) x_done = x_wr_req && dmem_gnt;
        end
        X_MUL: x_done = 1'b1;
        X_DIV: x_done = div_cnt == 0;
        X_AMO_ST: x_done = x_wr_req && dmem_gnt;
        default: ;
      endcase
    end
  end
  // Refetch what follows whenever the instruction may have changed how code is fetched:
  // fence.i, sfence.vma, any CSR access, and the privilege returns. Plain fence (which
  // includes the pause hint) is a no-op.
  assign x_refetch  = (op_miscmem && f3[0]) || is_sfence || is_csr || is_mret || is_sret;
  assign x_redirect = x_trap || (x_done && (x_npc != ir_pnpc || x_refetch));
  assign tlb_flush  = !rst_n || (x_done && (is_sfence || (is_csr && csr_write && csr_addr == 12'h180)));

  // value and destination handed to M
  logic        x_wen, x_fwen, x_is_load;
  logic [63:0] x_val;
  always_comb begin
    x_is_load = op_load || op_loadfp || is_lr;
    x_fwen = (op_loadfp || (fp_any && !fp_dest_int));
    x_wen  = rd != 5'd0 && !x_fwen && !(op_branch || op_store || op_storefp || op_miscmem ||
                                        (op_system && !is_csr));
    if (x_state == X_MUL)          x_val = op_op32 ? {{32{mul_p[31]}}, mul_p[31:0]} : f3[1:0] == 2'b00 ? mul_p[63:0] : mul_p[127:64];
    else if (x_state == X_DIV)     x_val = op_op32 ? {{32{div_result[31]}}, div_result[31:0]} : div_result;
    else if (x_state == X_AMO_ST)  x_val = amo_a;
    else if (fp_any)               x_val = fpu_result;
    else if (is_sc)                x_val = {63'b0, !sc_ok};
    else if (is_csr)               x_val = csr_rdata;
    else if (op_lui)               x_val = imm_u;
    else if (op_auipc)             x_val = ir_pc + imm_u;
    else if (op_jal || op_jalr)    x_val = pc_next;
    else                           x_val = alu_out;
  end

  // ------------------------------------------------------------------ M: load data
  logic [63:0] ld_shift, ld_data, m_wdata;
  logic        m_done;
  assign ld_shift = dmem_rdata >> {m_off, 3'b000};
  always_comb begin
    unique case (m_f3)
      3'b000: ld_data = {{56{ld_shift[7]}}, ld_shift[7:0]};
      3'b001: ld_data = {{48{ld_shift[15]}}, ld_shift[15:0]};
      3'b010: ld_data = m_box ? {32'hffff_ffff, ld_shift[31:0]} : {{32{ld_shift[31]}}, ld_shift[31:0]};
      3'b100: ld_data = {56'b0, ld_shift[7:0]};
      3'b101: ld_data = {48'b0, ld_shift[15:0]};
      3'b110: ld_data = {32'b0, ld_shift[31:0]};
      default: ld_data = ld_shift;
    endcase
  end
  assign m_wdata = m_load ? ld_data : m_val;
  assign m_done  = m_valid && m_free;

  assign tr_valid = m_done;
  assign tr_pc    = m_pc;
  assign tr_insn  = m_insn;
  assign tr_wen   = m_wen;
  assign tr_fwen  = m_fwen;
  assign tr_rd    = m_rd;
  assign tr_wdata = m_wdata;
  assign tr_trap  = x_trap;
  assign tr_trap_late = m_valid && !m_done;
  assign tr_cause = trap_cause;
  assign tr_epc   = ir_pc;
  assign tr_tval  = trap_tval;

  // ------------------------------------------------------------------ D: parcel buffer, extraction, prediction
  logic        arr_valid, ir_stays, e_c, e_have, e_take, e_rvc_ill, d_redirect;
  logic [31:0] arr_word, e_rvc_x, e_insn, e_raw;
  logic [63:0] win_data;
  logic [3:0]  win_flt;
  logic [2:0]  win_cnt;
  logic [1:0]  e_len, e_flt;
  logic [63:0] e_seq, e_tgt, e_pnpc, e_imm_j, e_imm_b;
  logic        e_jal, e_jalr, e_br, e_link_rd, e_link_rs1, e_call, e_ret;
  logic [1:0]  bht [1 << BHT_BITS];
  logic [1:0]  e_ctr;
  logic [63:0] ras [4];

  assign ir_stays  = ir_valid && !x_done && !x_trap;
  // x_redirect is deliberately not a term here: it arrives late, and on a redirect the window
  // is discarded anyway (e_take is false and the buffer count is cleared)
  assign arr_valid = pend_fetch && (pend_fault || imem_rvalid) && !pend_kill;
  assign arr_word  = pend_fault ? 32'h0 : imem_rdata;
  always_comb begin
    win_data = buf_data;
    win_flt  = buf_flt;
    win_cnt  = buf_cnt;
    if (arr_valid) begin
      if (pend_skip) begin
        win_data[16*buf_cnt[1:0]+:16] = arr_word[31:16];
        win_flt[buf_cnt[1:0]]         = pend_fault;
        win_cnt = buf_cnt + 3'd1;
      end else begin
        // the fetch was issued only with room for two parcels, so buf_cnt <= 2 here
        win_data[16*buf_cnt[1:0]+:32] = arr_word;
        win_flt[buf_cnt[1:0]+:2]      = {2{pend_fault}};
        win_cnt = buf_cnt + 3'd2;
      end
    end
  end

  legend64_rvc u_rvc (.c(win_data[15:0]), .x(e_rvc_x), .illegal(e_rvc_ill));

  assign e_c    = win_data[1:0] != 2'b11;
  assign e_flt  = win_flt[0] ? 2'd1 : (!e_c && win_flt[1]) ? 2'd2 : 2'd0;
  assign e_len  = (win_flt[0] || e_c) ? 2'd1 : 2'd2;
  assign e_have = win_cnt >= {1'b0, e_len};
  assign e_take = e_have && !ir_stays && !x_redirect;
  assign e_insn = e_c ? (e_rvc_ill ? 32'h0 : e_rvc_x) : win_data[31:0];
  assign e_raw  = e_c ? {16'h0, win_data[15:0]} : win_data[31:0];

  assign e_jal      = e_insn[6:0] == 7'b1101111;
  assign e_jalr     = e_insn[6:0] == 7'b1100111;
  assign e_br       = e_insn[6:0] == 7'b1100011;
  assign e_link_rd  = e_insn[11:7] == 5'd1 || e_insn[11:7] == 5'd5;
  assign e_link_rs1 = e_insn[19:15] == 5'd1 || e_insn[19:15] == 5'd5;
  assign e_call     = (e_jal || e_jalr) && e_link_rd;
  assign e_ret      = e_jalr && e_link_rs1 && !e_link_rd;
  assign e_imm_j    = {{43{e_insn[31]}}, e_insn[31], e_insn[19:12], e_insn[20], e_insn[30:21], 1'b0};
  assign e_imm_b    = {{51{e_insn[31]}}, e_insn[31], e_insn[7], e_insn[30:25], e_insn[11:8], 1'b0};
  assign e_seq      = buf_pc + (e_c ? 64'd2 : 64'd4);
  assign e_tgt      = buf_pc + (e_jal ? e_imm_j : e_imm_b);
  assign e_ctr      = bht[buf_pc[BHT_BITS:1]];
  assign e_pnpc     = e_flt != 2'd0 ? e_seq : e_jal ? e_tgt : (e_br && e_ctr[1]) ? e_tgt : e_ret ? ras[0] : e_seq;
  assign d_redirect = e_take && e_pnpc != e_seq;

  // ------------------------------------------------------------------ F: fetch address and translation
  logic        any_redirect, x_redir_slow, slot_free, want_fetch, i_xlate, i_noncanon, itlb_hit, i_perm_ok,
               i_fault_now, i_need_walk, fetch_issue, fault_issue;
  logic [2:0]  cnt_next;
  logic [63:0] fetch_va, fetch_pa;
  logic [43:0] itlb_ppn;
  logic [4:0]  itlb_perm;

  // a redirect that changes privilege or translation state waits one cycle, so that the fetch
  // is translated with the new state
  assign x_redir_slow = x_redirect && (x_trap || x_refetch);
  assign any_redirect = x_redirect || d_redirect;
  assign fetch_va     = x_redirect ? (x_trap ? trap_target : x_npc) : d_redirect ? e_pnpc : f_pc;
  assign cnt_next     = any_redirect ? 3'd0 : win_cnt - (e_take ? {1'b0, e_len} : 3'd0);
  assign slot_free    = !pend_fetch || pend_fault || imem_rvalid;
  assign want_fetch   = slot_free && cnt_next <= 3'd2 && !x_redir_slow && (!f_halt || any_redirect);

  assign fetch_vpn  = fetch_va[38:12];
  assign i_xlate    = satp_sv39 && priv != PRV_M;
  assign i_noncanon = fetch_va[63:39] != {25{fetch_va[38]}};
  assign i_perm_ok  = itlb_perm[2] && (priv == PRV_U ? itlb_perm[3] : !itlb_perm[3]);
  assign i_fault_now = i_xlate && (i_noncanon || (itlb_hit && !i_perm_ok) || (iptw_fault && iptw_fault_vpn == fetch_vpn));
  assign i_need_walk = i_xlate && !i_noncanon && !itlb_hit && !(iptw_fault && iptw_fault_vpn == fetch_vpn);
  assign fetch_pa    = i_xlate ? {8'b0, itlb_ppn, fetch_va[11:2], 2'b00} : {fetch_va[63:2], 2'b00};

  legend64_tlb #(.N(TLB_ENTRIES)) u_itlb (
      .clk, .flush(tlb_flush), .vpn(fetch_vpn), .hit(itlb_hit), .ppn(itlb_ppn), .perm(itlb_perm),
      .fill(ptw_fill_i), .fill_vpn(ptw_vpn), .fill_ppn(ptw_fill_ppn), .fill_level(ptw_level), .fill_perm(ptw_fill_perm)
  );

  assign imem_req    = want_fetch && !i_fault_now && !i_need_walk;
  assign imem_addr   = fetch_pa;
  assign fetch_issue = imem_req && imem_gnt;
  assign fault_issue = want_fetch && i_fault_now;
  assign iptw_want   = want_fetch && i_need_walk;

  // ------------------------------------------------------------------ sequential: memories
  logic [BHT_BITS-1:0] bht_idx;
  assign bht_idx = ir_pc[BHT_BITS:1];

  initial for (int i = 0; i < (1 << BHT_BITS); i++) bht[i] = 2'b01;

  // a two-bit saturating counter per entry
  logic [1:0] bht_cur, bht_next;
  assign bht_cur  = bht[bht_idx];
  assign bht_next = br_taken ? (bht_cur == 2'b11 ? 2'b11 : bht_cur + 2'd1)
                             : (bht_cur == 2'b00 ? 2'b00 : bht_cur - 2'd1);

  // The register files and the branch history table are memories: written a word at a time, read
  // by address, and not reset (a RAM has no reset; software and the predictor's training give
  // them their contents).
  always_ff @(posedge clk) begin
    if (m_done && m_wen)  regs[m_rd]  <= m_wdata;
    if (m_done && m_fwen) fregs[m_rd] <= m_wdata;
    // one write, so that the table is a memory with one write port to every synthesis tool
    if (x_done && op_branch) bht[bht_idx] <= bht_next;
  end
  // the return address stack is four registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ras[0] <= '0; ras[1] <= '0; ras[2] <= '0; ras[3] <= '0;
    end else if (e_take && e_flt == 2'd0) begin
      if (e_call) begin
        ras[0] <= e_seq; ras[1] <= ras[0]; ras[2] <= ras[1]; ras[3] <= ras[2];
      end else if (e_ret) begin
        ras[0] <= ras[1]; ras[1] <= ras[2]; ras[2] <= ras[3];
      end
    end
  end

  // The multiplier's product register, in a block of its own with a synchronous reset: the
  // output register of an FPGA's multiplier block has no asynchronous one, and with one here
  // the register could not be part of it.
  always_ff @(posedge clk) begin
    if (!rst_n) mul_p <= '0;
    else if (x_first && !x_trap && is_mul) mul_p <= mul_full[127:0];
  end

  // ------------------------------------------------------------------ sequential: pipeline and CSRs
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_pc <= RESET_PC; buf_pc <= RESET_PC; buf_cnt <= '0; buf_flt <= '0; f_halt <= 1'b0;
      pend_fetch <= 1'b0; pend_kill <= 1'b0; pend_fault <= 1'b0; pend_skip <= 1'b0;
      ir_valid <= 1'b0;
      x_state <= X_IDLE;
      m_valid <= 1'b0; m_wen <= 1'b0; m_fwen <= 1'b0; m_load <= 1'b0;
      ptw_state <= P_IDLE; ptw_kill <= 1'b0; ptw_for_i <= 1'b0; iptw_fault <= 1'b0; d_ptw_fault <= 1'b0;
      priv <= PRV_M;
      mstatus_sie <= 1'b0; mstatus_mie <= 1'b0; mstatus_spie <= 1'b0; mstatus_mpie <= 1'b0;
      mstatus_spp <= 1'b0; mstatus_mprv <= 1'b0; mstatus_sum <= 1'b0; mstatus_mxr <= 1'b0;
      mstatus_tvm <= 1'b0; mstatus_tw <= 1'b0; mstatus_tsr <= 1'b0;
      mstatus_mpp <= PRV_U; mstatus_fs <= 2'b00;
      mtvec <= '0; mscratch <= '0; mepc <= '0; mcause <= '0; mtval <= '0;
      stvec <= '0; sscratch <= '0; sepc <= '0; scause <= '0; stval <= '0;
      medeleg <= '0; mideleg_s <= 1'b0; mideleg_t <= 1'b0; mideleg_e <= 1'b0;
      mie_ssie <= 1'b0; mie_msie <= 1'b0; mie_stie <= 1'b0; mie_mtie <= 1'b0; mie_seie <= 1'b0; mie_meie <= 1'b0;
      mip_ssip <= 1'b0; mip_stip <= 1'b0; mip_seip <= 1'b0;
      mcycle <= '0; minstret <= '0;
      mcounteren <= '0; scounteren <= '0; satp_sv39 <= 1'b0; satp_ppn <= '0;
      fflags <= '0; frm <= '0;
      resv_valid <= 1'b0;
      // the data registers of the pipeline, the multiplier, the divider and the page-table
      // walker: nothing reads them before they are loaded, but none is left without a value
      buf_data <= '0;
      ir <= '0; ir_raw <= '0; ir_c <= 1'b0; ir_flt <= '0; ir_pc <= '0; ir_pnpc <= '0;
      m_rd <= '0; m_val <= '0; m_pc <= '0; m_insn <= '0; m_f3 <= '0; m_off <= '0; m_box <= 1'b0;
      amo_data <= '0; amo_paddr <= '0; resv_addr <= '0;
      div_rem <= '0; div_quo <= '0; div_den <= '0; div_cnt <= '0; div_neg_q <= 1'b0; div_neg_r <= 1'b0;
      ptw_vpn <= '0; ptw_level <= '0; ptw_a <= '0; iptw_fault_vpn <= '0;
    end else begin
      // ---- fetch
      if (fetch_issue || fault_issue) begin
        pend_fetch <= 1'b1; pend_kill <= 1'b0; pend_fault <= fault_issue; pend_skip <= fetch_va[1];
        f_pc <= {fetch_va[63:2], 2'b00} + 64'd4;
      end else begin
        if (pend_fault || imem_rvalid) begin pend_fetch <= 1'b0; pend_kill <= 1'b0; pend_fault <= 1'b0; end
        else if (any_redirect && pend_fetch) pend_kill <= 1'b1;
        f_pc <= fetch_va;
      end
      if (any_redirect) f_halt <= fault_issue;
      else if (fault_issue) f_halt <= 1'b1;
      if (any_redirect || fault_issue) iptw_fault <= 1'b0;

      // ---- parcel buffer
      if (any_redirect) begin
        buf_cnt <= '0; buf_flt <= '0;
        buf_pc  <= fetch_va;
      end else begin
        buf_cnt <= cnt_next;
        if (e_take) begin
          buf_data <= e_len == 2'd2 ? {32'b0, win_data[63:32]} : {16'b0, win_data[63:16]};
          buf_flt  <= e_len == 2'd2 ? {2'b0, win_flt[3:2]} : {1'b0, win_flt[3:1]};
          buf_pc   <= buf_pc + (e_len == 2'd2 ? 64'd4 : 64'd2);
        end else begin
          buf_data <= win_data;
          buf_flt  <= win_flt;
        end
      end

      // ---- instruction register
      if (x_redirect) ir_valid <= 1'b0;
      else if (!ir_stays) begin
        ir_valid <= e_take;
        ir <= e_insn; ir_raw <= e_raw; ir_c <= e_c; ir_flt <= e_flt;
        ir_pc <= buf_pc; ir_pnpc <= e_pnpc;
      end

      // ---- page-table walker
      unique case (ptw_state)
        P_IDLE: if (ptw_start_d || ptw_start_i) begin
          ptw_state <= P_REQ;
          ptw_for_i <= !ptw_start_d;
          ptw_kill  <= 1'b0;
          ptw_vpn   <= ptw_start_d ? ea[38:12] : fetch_vpn;
          ptw_level <= 2'd2;
          ptw_a     <= satp_ppn;
        end
        P_REQ: if (dmem_gnt) ptw_state <= P_WAIT;
        P_WAIT: if (dmem_rvalid) begin
          if (pte_fault) begin
            ptw_state <= P_IDLE;
            if (!ptw_for_i) d_ptw_fault <= 1'b1;
            else if (!ptw_kill && !any_redirect) begin iptw_fault <= 1'b1; iptw_fault_vpn <= ptw_vpn; end
          end else if (pte_leaf) begin
            ptw_state <= P_IDLE;
          end else begin
            ptw_state <= P_REQ;
            ptw_level <= ptw_level - 2'd1;
            ptw_a     <= pte[53:10];
          end
        end
        default: ptw_state <= P_IDLE;
      endcase
      if (any_redirect && ptw_busy && ptw_for_i) ptw_kill <= 1'b1;
      if (x_done || x_trap) d_ptw_fault <= 1'b0;

      // ---- M
      if (m_free) begin
        m_valid <= x_done;
        m_wen   <= x_done && x_wen;
        m_fwen  <= x_done && x_fwen;
        m_load  <= x_done && x_state == X_IDLE && x_is_load;
        m_box   <= op_loadfp;
        m_rd    <= rd;
        m_val   <= x_val;
        m_f3    <= f3;
        m_off   <= ea[2:0];
        m_pc    <= ir_pc;
        m_insn  <= ir_raw;
      end

      // ---- X multi-cycle state
      unique case (x_state)
        X_IDLE: if (x_first && !x_trap) begin
          if (is_mul) begin
            x_state <= X_MUL;      // the product is registered below
          end else if (is_div) begin
            x_state   <= X_DIV;
            div_cnt   <= 7'd64;
            div_rem   <= '0;
            div_quo   <= (div_signed && div_a[63]) ? -div_a : div_a;
            div_den   <= (div_signed && div_b[63]) ? -div_b : div_b;
            div_neg_q <= div_signed && (div_a[63] ^ div_b[63]) && div_b != '0;
            div_neg_r <= div_signed && div_a[63];
          end else if (is_amo_rmw && x_rd_req && dmem_gnt) begin
            x_state   <= X_AMO_WAIT;
            amo_paddr <= d_paddr;
          end
        end
        X_MUL: if (x_done) x_state <= X_IDLE;
        X_DIV: begin
          if (div_cnt == 0) begin
            if (x_done) x_state <= X_IDLE;
          end else begin
            div_cnt <= div_cnt - 7'd1;
            if (!div_sub[65]) begin
              div_rem <= div_sub[63:0]; div_quo <= {div_quo[62:0], 1'b1};
            end else begin
              div_rem <= div_shift[63:0]; div_quo <= {div_quo[62:0], 1'b0};
            end
          end
        end
        X_AMO_WAIT: if (dmem_rvalid) begin
          amo_data <= dmem_rdata >> {ea[2:0], 3'b000};
          x_state  <= X_AMO_ST;
        end
        X_AMO_ST: if (x_done) x_state <= X_IDLE;
        default: x_state <= X_IDLE;
      endcase

      // ---- architectural updates at the commit point
      mcycle <= mcycle + 64'd1;
      if (x_done) begin
        minstret <= minstret + 64'd1;
        if (is_lr) begin resv_valid <= 1'b1; resv_addr <= d_paddr; end
        if (is_sc) resv_valid <= 1'b0;
        if (fp_any) begin
          fflags <= fflags | fpu_flags;
          if (x_fwen || |fpu_flags) mstatus_fs <= 2'b11;
        end
        if (op_loadfp) mstatus_fs <= 2'b11;
        if (is_mret) begin
          priv         <= mstatus_mpp;
          mstatus_mie  <= mstatus_mpie;
          mstatus_mpie <= 1'b1;
          mstatus_mpp  <= PRV_U;
          if (mstatus_mpp != PRV_M) mstatus_mprv <= 1'b0;
          resv_valid   <= 1'b0;
        end
        if (is_sret) begin
          priv         <= {1'b0, mstatus_spp};
          mstatus_sie  <= mstatus_spie;
          mstatus_spie <= 1'b1;
          mstatus_spp  <= 1'b0;
          mstatus_mprv <= 1'b0;
          resv_valid   <= 1'b0;
        end
        if (is_csr && csr_write) begin
          unique case (csr_addr)
            12'h001: begin fflags <= csr_wdata[4:0]; mstatus_fs <= 2'b11; end
            12'h002: begin frm <= csr_wdata[2:0]; mstatus_fs <= 2'b11; end
            12'h003: begin fflags <= csr_wdata[4:0]; frm <= csr_wdata[7:5]; mstatus_fs <= 2'b11; end
            12'h100, 12'h300: begin
              mstatus_sie  <= csr_wdata[1];
              mstatus_spie <= csr_wdata[5];
              mstatus_spp  <= csr_wdata[8];
              mstatus_fs   <= csr_wdata[14:13];
              mstatus_sum  <= csr_wdata[18];
              mstatus_mxr  <= csr_wdata[19];
              if (csr_addr == 12'h300) begin
                mstatus_mie  <= csr_wdata[3];
                mstatus_mpie <= csr_wdata[7];
                if (csr_wdata[12:11] != 2'b10) mstatus_mpp <= csr_wdata[12:11];
                mstatus_mprv <= csr_wdata[17];
                mstatus_tvm  <= csr_wdata[20];
                mstatus_tw   <= csr_wdata[21];
                mstatus_tsr  <= csr_wdata[22];
              end
            end
            12'h104: begin
              if (mideleg_s) mie_ssie <= csr_wdata[1];
              if (mideleg_t) mie_stie <= csr_wdata[5];
              if (mideleg_e) mie_seie <= csr_wdata[9];
            end
            12'h105: stvec <= {csr_wdata[63:2], 1'b0, csr_wdata[0]};
            12'h106: scounteren <= csr_wdata[2:0];
            12'h140: sscratch <= csr_wdata;
            12'h141: sepc <= {csr_wdata[63:1], 1'b0};
            12'h142: scause <= csr_wdata;
            12'h143: stval <= csr_wdata;
            12'h144: if (mideleg_s) mip_ssip <= csr_wdata[1];
            12'h180: if (csr_wdata[63:60] == 4'd0 || csr_wdata[63:60] == 4'd8) begin
              satp_sv39 <= csr_wdata[63];
              satp_ppn  <= csr_wdata[43:0];
            end
            12'h302: medeleg <= csr_wdata[15:0] & 16'hb3ff;
            12'h303: begin mideleg_s <= csr_wdata[1]; mideleg_t <= csr_wdata[5]; mideleg_e <= csr_wdata[9]; end
            12'h304: begin
              mie_ssie <= csr_wdata[1]; mie_msie <= csr_wdata[3]; mie_stie <= csr_wdata[5];
              mie_mtie <= csr_wdata[7]; mie_seie <= csr_wdata[9]; mie_meie <= csr_wdata[11];
            end
            12'h305: mtvec <= {csr_wdata[63:2], 1'b0, csr_wdata[0]};
            12'h306: mcounteren <= csr_wdata[2:0];
            12'h340: mscratch <= csr_wdata;
            12'h341: mepc <= {csr_wdata[63:1], 1'b0};
            12'h342: mcause <= csr_wdata;
            12'h343: mtval <= csr_wdata;
            // SEIP reads as the software bit ORed with the interrupt controller's line, but a
            // set or clear must modify the software bit alone: otherwise setting another bit
            // of mip while the line is high would latch SEIP for ever
            12'h344: begin
              mip_ssip <= csr_wdata[1]; mip_stip <= csr_wdata[5];
              mip_seip <= f3[1:0] == 2'b01 ? csr_src[9] : f3[1:0] == 2'b10 ? mip_seip | csr_src[9] : mip_seip & ~csr_src[9];
            end
            12'hb00: mcycle <= csr_wdata;
            12'hb02: minstret <= csr_wdata;
            default: ;
          endcase
        end
      end
      if (x_trap) begin
        resv_valid <= 1'b0;
        if (trap_to_s) begin
          sepc         <= ir_pc;
          scause       <= trap_cause;
          stval        <= trap_tval;
          mstatus_spie <= mstatus_sie;
          mstatus_sie  <= 1'b0;
          mstatus_spp  <= priv[0];
          priv         <= PRV_S;
        end else begin
          mepc         <= ir_pc;
          mcause       <= trap_cause;
          mtval        <= trap_tval;
          mstatus_mpie <= mstatus_mie;
          mstatus_mie  <= 1'b0;
          mstatus_mpp  <= priv;
          priv         <= PRV_M;
        end
      end
    end
  end
endmodule
