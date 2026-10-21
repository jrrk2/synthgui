// A CDC 6000 series central processor (the integer, shift, floating point and branch instructions that the
// 1972 Pascal compiler's code generator emits) in the style of ocaml4142_vm_rtl.sv: one state machine, one
// synchronous memory, a load port while in reset, strobe outputs for I/O, no C runtime.
//
// Registers  X0-X7 60 bit, A0-A7 and B0-B7 18 bit (B0 = 0), P a word address.
// Memory     MEM_AW address bits of 60 bit words; instruction fetch reads one word, up to four 15 bit parcels.
// Boot       words 1, 2, 3 of memory hold the entry point, B5 (frame base) and B4 (stack limit); X7 = 0100B, the
//            address of the runtime's HALT vector.  (pasclgo2img.py writes them.)
// I/O words  020B IO_RX  load: next input character (display code, line end = 0), all ones at end of input; the
//                        instruction waits for rx_valid, rx_take pulses when the character is consumed
//            021B IO_TX  store: output character          -> tx_valid / tx_char   (waits for tx_ready)
//            022B IO_FILE store: name of the binary file  -> remembered
//            023B IO_FWORD store: a word of that file     -> fo_valid / fo_name / fo_word (waits for fo_ready)
//            024B IO_HALT store: stop
// Device     DEV_BASE (120000B) .. +4111: the Ethernet device window of nfs/nfsdrv.pas, on the dev_* bus below
// The runtime (GETC, PUTC, WRTI ... ) is CDC machine code in memory at 0100B..: see host/mkrt.py.
module cdc6000_core #(
    parameter int MEM_AW = 17,
    // initial memory image ($readmemh); runtime and program are normally written through the load port
    parameter MEM_INIT = "",
    // EXT_MEM: the memory is outside (explicit block RAMs, fpga/vc707-eth/genmem.py): one synchronous port, address
    // ext_addr, the word read arrives the cycle after.  Otherwise it is an array in here.
    parameter bit EXT_MEM = 1'b0
) (
    input logic clk,
    input logic reset,

    output logic [MEM_AW-1:0] ext_addr,
    output logic              ext_we,
    output logic [59:0]       ext_wdata,
    input  logic [59:0]       ext_rdata,

    // load port: while reset is held, load_we writes load_data to mem[load_addr]
    input  logic                load_we,
    input  logic [MEM_AW-1:0]   load_addr,
    input  logic [59:0]         load_data,

    // input characters
    input  logic        rx_valid,
    input  logic [5:0]  rx_char,
    input  logic        rx_eof,
    output logic        rx_take,

    // output characters
    output logic        tx_valid,
    output logic [5:0]  tx_char,
    input  logic        tx_ready,

    // binary file words
    output logic        fo_valid,
    output logic [59:0] fo_name,
    output logic [59:0] fo_word,
    input  logic        fo_ready,

    // device window (the Ethernet/NFS device): a load or store to DEV_BASE .. DEV_BASE+4111 becomes a request on this bus.
    // dev_req stays high until dev_ack; for a load dev_rdata is sampled with dev_ack.
    output logic        dev_req,
    output logic        dev_we,
    output logic [12:0] dev_off,
    output logic [59:0] dev_wdata,
    input  logic        dev_ack,
    input  logic [59:0] dev_rdata,

    output logic        halted,
    output logic        fault,          // PS executed, a bad opcode, or a 30 bit instruction in the last parcel

    // debug
    output logic [17:0] dbg_pc,
    output logic [63:0] icount,
    output logic [479:0] dbg_x,        // X0 .. X7, X0 in the low bits
    output logic [143:0] dbg_a,        // A0 .. A7
    output logic [143:0] dbg_b         // B0 .. B7
);
  import cdc_pkg::*;

  // ------------------------------------------------------------------ memory
  logic [59:0] mem[0:(1<<MEM_AW)-1];
  logic [59:0] rdata;
  logic [MEM_AW-1:0] raddr, waddr;
  logic [59:0] wdata;
  logic mem_we;

  generate
    if (EXT_MEM) begin : g_ext
      assign ext_addr  = mem_we ? waddr : raddr;
      assign ext_we    = mem_we;
      assign ext_wdata = wdata;
      assign rdata     = ext_rdata;
    end else begin : g_int
      assign ext_addr = '0; assign ext_we = 1'b0; assign ext_wdata = 60'd0;
      initial begin
        if (MEM_INIT != "") $readmemh(MEM_INIT, mem);
      end
      always_ff @(posedge clk) begin
        if (reset) begin
          if (load_we) mem[load_addr] <= load_data;
        end else if (mem_we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
      end
    end
  endgenerate

  // ------------------------------------------------------------------ registers
  logic [59:0] x[0:7];
  logic [17:0] a[0:7];
  logic [17:0] b[0:7];
  logic [17:0] p;
  logic [59:0] iw;
  logic [1:0]  slot;
  logic [59:0] io_file;

  typedef enum logic [3:0] {
    S_B0, S_B1, S_B2, S_B3, S_FETCH, S_FETCHW, S_EXEC, S_LDW, S_DIV, S_FPN, S_DEV, S_HALT
  } state_t;
  state_t state;

  // an instruction that needs more than one cycle remembers where to go afterwards
  logic        pend_end;       // it was the last parcel of the word
  logic [2:0]  pend_x;         // register that receives the loaded / divided value
  logic        pend_io;        // the load is from IO_RX
  logic        pend_dev_we;    // S_DEV: the access is a store
  logic [12:0] pend_dev_off;
  logic [59:0] pend_dev_wd;

  // division (FX/ RX/): restoring, one quotient bit per cycle
  logic [47:0] dv_xc, dv_yc;
  logic        dv_neg, dv_round;
  int          dv_e;
  logic [49:0] dv_r;
  logic [50:0] dv_q;
  logic [5:0]  dv_cnt;

  // ------------------------------------------------------------------ instruction decode
  logic [14:0] pc0, pc1;
  logic [5:0]  fm;
  logic [2:0]  fi, fj, fk;
  logic [17:0] K;
  logic        is_long;

  always_comb begin
    case (slot)
      2'd0: begin pc0 = iw[59:45]; pc1 = iw[44:30]; end
      2'd1: begin pc0 = iw[44:30]; pc1 = iw[29:15]; end
      2'd2: begin pc0 = iw[29:15]; pc1 = iw[14:0]; end
      default: begin pc0 = iw[14:0]; pc1 = 15'd0; end
    endcase
    fm = pc0[14:9]; fi = pc0[8:6]; fj = pc0[5:3]; fk = pc0[2:0];
    K = {fk, pc1};
    is_long = (fm >= 6'o01 && fm <= 6'o07) || fm == 6'o50 || fm == 6'o51 || fm == 6'o52 ||
              fm == 6'o60 || fm == 6'o61 || fm == 6'o62 || fm == 6'o70 || fm == 6'o71 || fm == 6'o72;
  end

  // register reads
  logic [17:0] bi_v, bj_v, bk_v;
  logic [59:0] xi_v, xj_v, xk_v;
  logic [17:0] aj_v;
  always_comb begin
    bi_v = (fi == 0) ? 18'd0 : b[fi];
    bj_v = (fj == 0) ? 18'd0 : b[fj];
    bk_v = (fk == 0) ? 18'd0 : b[fk];
    xi_v = x[fi]; xj_v = x[fj]; xk_v = x[fk];
    aj_v = a[fj];
  end

  // ------------------------------------------------------------------ execute (combinational)
  logic        xw, bw, aw, jump, halt_i, fault_i, ldreq, div_go, stall;
  logic [2:0]  xwi, bwi, awi;
  logic [59:0] xwv;
  logic [17:0] bwv, awv, jt, ldaddr;
  logic        st_mem, st_tx, st_file, st_fword;
  logic [17:0] staddr;
  logic        ld_io, ld_dev, st_dev;
  logic        rj;
  logic [17:0] s18;
  logic [2:0]  nslot;
  logic [17:0] bsh;
  logic        shl;
  logic [5:0]  shn;
  logic signed [18:0] va, vb;
  fl_t         dx, dy;
  int          dnx, dny;

  localparam logic [17:0] DEV_BASE = 18'o120000;
  // ---- the floating point datapath: one multiplier, one adder/aligner, one normaliser (in S_FPN) ----
  logic [95:0] mulp;
  nrm_t        add_n, mul_n;
  logic [59:0] dmul_v;
  logic        fp_go;
  logic        fp_round_x;
  nrm_t        fp_n;           // the staged operation (S_FPN works on the registered copy)
  nrm_t        fp_nr;
  logic        fp_roundr;
  fl_t fpx, fpy;
  always_comb begin
    fpx    = funpack(xj_v);
    fpy    = funpack(xk_v);
    mulp   = {48'd0, fpx.c} * {48'd0, fpy.c};
    add_n  = add_prep(xj_v, xk_v, fm[0]);
    mul_n  = mul_prep(xj_v, xk_v, mulp);
    dmul_v = dmul_from(xj_v, xk_v, mulp);
  end

  function automatic logic is_dev(input logic [17:0] ad);
    is_dev = (ad >= DEV_BASE) && (ad < DEV_BASE + 18'd4112);
  endfunction

  function automatic logic is_io(input logic [17:0] ad);
    is_io = (ad[17:5] == 13'd0) && ad[4] && !ad[3] && (ad[2:0] <= 3'd4);
  endfunction

  function automatic logic cond(input logic [2:0] c, input logic [59:0] v);
    logic [11:0] e;
    logic inr, ind;
    e = v[59:48];
    ind = (e == 12'o1777) || (e == 12'o6000);
    inr = (e == 12'o3777) || (e == 12'o4000) || ind;
    case (c)
      3'd0: cond = (v == 60'd0) || (v == M60);
      3'd1: cond = !((v == 60'd0) || (v == M60));
      3'd2: cond = !v[59];
      3'd3: cond = v[59];
      3'd4: cond = !inr;
      3'd5: cond = inr;
      3'd6: cond = !ind;
      default: cond = ind;
    endcase
  endfunction

  always_comb begin
    xw = 0; bw = 0; aw = 0; jump = 0; halt_i = 0; fault_i = 0; ldreq = 0; div_go = 0; fp_go = 0; fp_n = '0; fp_round_x = 0;
    xwi = fi; bwi = fi; awi = fi; xwv = 60'd0; bwv = 18'd0; awv = 18'd0; jt = 18'd0;
    st_mem = 0; st_tx = 0; st_file = 0; st_fword = 0; staddr = 18'd0; ld_io = 0; ld_dev = 0; st_dev = 0; rj = 0;
    ldaddr = 18'd0;
    s18 = 18'd0; shl = 1; shn = 6'd0; bsh = 18'd0; va = 0; vb = 0;
    dx = funpack(xj_v); dy = funpack(xk_v);
    dnx = 0; dny = 0;
    nslot = {1'b0, slot} + (is_long ? 3'd2 : 3'd1);

    // the sum of the SA/SB/SX families
    case (fm[2:0])
      3'd0: s18 = add18(K, aj_v);
      3'd1: s18 = add18(K, bj_v);
      3'd2: s18 = add18(K, xj_v[17:0]);
      3'd3: s18 = add18(bk_v, xj_v[17:0]);
      3'd4: s18 = add18(bk_v, aj_v);
      3'd5: s18 = add18(neg18(bk_v), aj_v);
      3'd6: s18 = add18(bk_v, bj_v);
      default: s18 = add18(neg18(bk_v), bj_v);
    endcase
    shn = shcount(bj_v); shl = !bj_v[17];
    va = sb18(bi_v); vb = sb18(bj_v);

    if (state == S_EXEC) begin
      case (fm)
        6'o00: begin halt_i = 1; fault_i = 1; end
        6'o01: begin rj = 1; staddr = K; jump = 1; jt = K + 18'd1; end
        6'o02: begin jump = 1; jt = K + bi_v; end
        6'o03: if (cond(fi, xj_v)) begin jump = 1; jt = K; end
        6'o04: if (va == vb) begin jump = 1; jt = K; end
        6'o05: if (va != vb) begin jump = 1; jt = K; end
        6'o06: if (va >= vb) begin jump = 1; jt = K; end
        6'o07: if (va < vb) begin jump = 1; jt = K; end
        6'o10: begin xw = 1; xwv = xj_v; end
        6'o11: begin xw = 1; xwv = xj_v & xk_v; end
        6'o12: begin xw = 1; xwv = xj_v | xk_v; end
        6'o13: begin xw = 1; xwv = xj_v ^ xk_v; end
        6'o14: begin xw = 1; xwv = ~xk_v; end
        6'o15: begin xw = 1; xwv = ~xk_v & xj_v; end
        6'o16: begin xw = 1; xwv = ~xk_v | xj_v; end
        6'o17: begin xw = 1; xwv = ~(xk_v ^ xj_v); end
        6'o20: begin xw = 1; xwv = rotl60(xi_v, {fj, fk}); end
        6'o21: begin xw = 1; xwv = sar60(xi_v, {fj, fk}); end
        6'o22: begin xw = 1; xwv = shl ? rotl60(xk_v, shn) : sar60(xk_v, shn); end
        6'o23: begin xw = 1; xwv = shl ? sar60(xk_v, shn) : rotl60(xk_v, shn); end
        6'o24, 6'o25: begin
          xw = 1; xwv = nx_result(xk_v);
          if (fj != 0) begin bw = 1; bwi = fj; bwv = nx_count(xk_v); end
        end
        6'o26: begin
          xw = 1; xwv = ux_coef(xk_v);
          if (fj != 0) begin bw = 1; bwi = fj; bwv = ux_exp(xk_v); end
        end
        6'o27: begin xw = 1; xwv = px_result(xk_v, bj_v); end
        6'o30, 6'o31, 6'o32, 6'o33, 6'o34, 6'o35: begin fp_go = 1; fp_n = add_n; fp_round_x = fm[2]; end
        6'o36: begin xw = 1; xwv = add60(xj_v, xk_v); end
        6'o37: begin xw = 1; xwv = add60(xj_v, ~xk_v); end
        6'o40, 6'o41: begin fp_go = 1; fp_n = mul_n; fp_round_x = fm[0]; end
        6'o42: begin xw = 1; xwv = dmul_v; end
        6'o43: begin xw = 1; xwv = mask43({fj, fk}); end
        6'o44, 6'o45: begin
          if (dy.c == 0) begin xw = 1; xwv = {12'h3ff, 48'd0}; end
          else if (dx.c == 0) begin xw = 1; xwv = 60'd0; end
          else div_go = 1;
        end
        6'o46: ;
        6'o47: begin xw = 1; xwv = popcount60(xk_v); end
        6'o50, 6'o51, 6'o52, 6'o53, 6'o54, 6'o55, 6'o56, 6'o57: begin
          aw = 1; awv = s18;
          if (fi >= 1 && fi <= 5) begin
            ldreq = 1; ldaddr = s18; ld_io = is_io(s18); ld_dev = is_dev(s18);
          end
          else if (fi >= 6) begin
            staddr = s18;
            if (is_dev(s18)) st_dev = 1;
            else if (is_io(s18)) begin
              st_tx = (s18[2:0] == 3'd1); st_file = (s18[2:0] == 3'd2); st_fword = (s18[2:0] == 3'd3);
              halt_i = (s18[2:0] == 3'd4);
            end else st_mem = 1;
          end
        end
        6'o60, 6'o61, 6'o62, 6'o63, 6'o64, 6'o65, 6'o66, 6'o67: begin
          if (fi != 0) begin bw = 1; bwv = s18; end
        end
        6'o70, 6'o71, 6'o72, 6'o73, 6'o74, 6'o75, 6'o76, 6'o77: begin
          xw = 1; xwv = sx18(s18);
        end
        default: begin fault_i = 1; halt_i = 1; end
      endcase
      if (is_long && slot == 2'd3) begin fault_i = 1; halt_i = 1; end
    end
    stall = (state == S_EXEC) && ((st_tx && !tx_ready) || (st_fword && !fo_ready));
  end

  // ------------------------------------------------------------------ memory address / write mux
  always_comb begin
    raddr = '0; mem_we = 0; waddr = '0; wdata = 60'd0;
    case (state)
      S_B0: raddr = MEM_AW'(1);
      S_B1: raddr = MEM_AW'(2);
      S_B2: raddr = MEM_AW'(3);
      S_FETCH: raddr = MEM_AW'(p);
      S_EXEC: begin
        raddr = MEM_AW'(ldaddr);
        if (!stall) begin
          if (st_mem) begin mem_we = 1; waddr = MEM_AW'(staddr); wdata = xi_v; end
          if (rj) begin mem_we = 1; waddr = MEM_AW'(staddr); wdata = {6'o04, 6'o00, 18'(p + 18'd1), 30'd0}; end
        end
      end
      default: ;
    endcase
  end

  // ------------------------------------------------------------------ the state machine
  assign dbg_pc = p;
  always_comb begin
    for (int q = 0; q < 8; q++) begin
      dbg_x[60*q +: 60] = x[q]; dbg_a[18*q +: 18] = a[q]; dbg_b[18*q +: 18] = b[q];
    end
  end

  always_ff @(posedge clk) begin
    rx_take <= 1'b0; tx_valid <= 1'b0; fo_valid <= 1'b0;
    if (reset) begin
      state <= S_B0; halted <= 1'b0; fault <= 1'b0; icount <= 64'd0;
      for (int q = 0; q < 8; q++) begin x[q] <= 60'd0; a[q] <= 18'd0; b[q] <= 18'd0; end
      p <= 18'd0; slot <= 2'd0; io_file <= 60'd0;
    end else begin
      case (state)
        S_B0: state <= S_B1;
        S_B1: begin p <= rdata[17:0]; state <= S_B2; end                       // mem[1]: entry point
        S_B2: begin b[5] <= rdata[17:0]; b[6] <= rdata[17:0]; state <= S_B3; end   // mem[2]: B5 = B6
        S_B3: begin b[4] <= rdata[17:0]; x[7] <= 60'o100; state <= S_FETCH; end    // mem[3]: B4
        S_FETCH: state <= S_FETCHW;
        S_FETCHW: begin iw <= rdata; slot <= 2'd0; state <= S_EXEC; end
        S_EXEC: if (!stall) begin
          icount <= icount + 64'd1;
          if (xw) x[xwi] <= xwv;
          if (bw && bwi != 0) b[bwi] <= bwv;
          if (aw) a[awi] <= awv;
          if (st_tx) begin tx_valid <= 1'b1; tx_char <= xi_v[5:0]; end
          if (st_file) io_file <= xi_v;
          if (st_fword) begin fo_valid <= 1'b1; fo_name <= io_file; fo_word <= xi_v; end
          if (fault_i) fault <= 1'b1;
          if (halt_i) begin halted <= 1'b1; state <= S_HALT; end
          else if (jump) begin p <= jt; state <= S_FETCH; end
          else if (st_dev) begin
            pend_end <= nslot[2]; slot <= nslot[1:0]; pend_x <= fi;
            pend_dev_we <= 1'b1; pend_dev_off <= staddr[12:0]; pend_dev_wd <= xi_v; state <= S_DEV;
          end
          else if (ldreq && ld_dev) begin
            pend_end <= nslot[2]; slot <= nslot[1:0]; pend_x <= fi;
            pend_dev_we <= 1'b0; pend_dev_off <= ldaddr[12:0]; pend_dev_wd <= 60'd0; state <= S_DEV;
          end
          else if (fp_go) begin
            pend_end <= nslot[2]; slot <= nslot[1:0]; pend_x <= fi;
            fp_nr <= fp_n; fp_roundr <= fp_round_x; state <= S_FPN;
          end
          else if (ldreq || div_go) begin
            pend_end <= nslot[2]; slot <= nslot[1:0]; pend_x <= fi; pend_io <= ld_io;
            if (div_go) begin
              dv_neg <= dx.neg ^ dy.neg; dv_round <= fm[0];
              dv_xc <= dx.c << clz48(dx.c); dv_yc <= dy.c << clz48(dy.c);
              dv_e <= int'(dx.e) - clz48(dx.c) - (int'(dy.e) - clz48(dy.c)) - 50;
              dv_cnt <= 6'd0; dv_q <= 51'd0; dv_r <= 50'd0;
              state <= S_DIV;
            end else state <= S_LDW;
          end
          else if (nslot[2]) begin p <= p + 18'd1; state <= S_FETCH; end
          else slot <= nslot[1:0];
        end
        S_LDW: begin
          if (!pend_io) begin
            x[pend_x] <= rdata;
            state <= pend_end ? S_FETCH : S_EXEC;
            if (pend_end) p <= p + 18'd1;
          end else if (rx_valid) begin
            x[pend_x] <= rx_eof ? M60 : {54'd0, rx_char};
            rx_take <= 1'b1;
            state <= pend_end ? S_FETCH : S_EXEC;
            if (pend_end) p <= p + 18'd1;
          end
        end
        S_DIV: begin
          logic [49:0] rr;
          logic        qb;
          rr = (dv_cnt == 6'd0) ? {2'b00, dv_xc} : {dv_r[48:0], 1'b0};
          qb = (rr >= {2'b00, dv_yc});
          if (qb) rr = rr - {2'b00, dv_yc};
          dv_q <= {dv_q[49:0], qb};
          dv_r <= rr;
          if (dv_cnt == 6'd50) begin       // the 51st quotient bit: hand over to the normaliser
            fp_nr.zero <= 1'b0; fp_nr.neg <= dv_neg; fp_nr.m <= NW'({dv_q[49:0], qb}); fp_nr.e <= 16'(dv_e);
            fp_roundr <= dv_round;
            state <= S_FPN;
          end
          dv_cnt <= dv_cnt + 6'd1;
        end
        S_FPN: begin
          x[pend_x] <= fnorm(fp_nr, fp_roundr);
          state <= pend_end ? S_FETCH : S_EXEC;
          if (pend_end) p <= p + 18'd1;
        end
        S_DEV: if (dev_ack) begin
          if (!pend_dev_we) x[pend_x] <= dev_rdata;
          state <= pend_end ? S_FETCH : S_EXEC;
          if (pend_end) p <= p + 18'd1;
        end
        S_HALT: ;
        default: ;
      endcase
    end
  end

  assign dev_req   = (state == S_DEV);
  assign dev_we    = pend_dev_we;
  assign dev_off   = pend_dev_off;
  assign dev_wdata = pend_dev_wd;

`ifndef SYNTHESIS
  // +trace: one line per executed instruction, "P/slot" -- the same lines cdcemu -t prints
  logic trace_en;
  initial trace_en = $test$plusargs("trace");
  always @(posedge clk) if (!reset && trace_en && state == S_EXEC && !stall) $display("T %o/%0d", p, slot);
`endif
endmodule
