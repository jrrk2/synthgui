// SPDX-License-Identifier: Apache-2.0
// legend64_fpu: IEEE 754 single and double precision unit for the F and D extensions.
//
// Multi-cycle and unpipelined: the core holds the instruction and its operands steady from
// `start` until `done && accept`. All arithmetic funnels into one back end:
//
//   front end (FMA / divide / square root / conversions)
//        -> an exact unsigned integer INT with a binary scale: value = INT * 2^base
//        -> NORM  (find the leading one, keep 64 bits plus sticky)
//        -> ROUND (round to the target format, detect overflow/underflow, pack)
//
// fadd, fsub and fmul run through the fused multiply-add datapath (a*1+c, a*b+0), so there is
// one adder and one rounding path to get right. Compares, sign injection, min/max, classify,
// moves and float-to-integer conversion are combinational and finish in the start cycle.

module legend64_fpu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,    // an FP operation is in the execute stage (level)
    input  logic        accept,   // the core takes the result this cycle
    input  logic [31:0] insn,
    input  logic [63:0] a_raw,    // f[rs1]
    input  logic [63:0] b_raw,    // f[rs2]
    input  logic [63:0] c_raw,    // f[rs3]
    input  logic [63:0] x_in,     // x[rs1], for integer-to-float and fmv
    input  logic [2:0]  rm,       // resolved rounding mode
    output logic        busy,     // a multi-cycle operation is in flight
    output logic        done,
    output logic [63:0] result,
    output logic [4:0]  flags     // {NV, DZ, OF, UF, NX}
);
  localparam logic [2:0] RNE = 3'd0, RTZ = 3'd1, RDN = 3'd2, RUP = 3'd3, RMM = 3'd4;
  localparam logic [63:0] QNAN_D = 64'h7ff8_0000_0000_0000;
  localparam logic [63:0] QNAN_S = 64'hffff_ffff_7fc0_0000;

  typedef struct packed {
    logic               sign;
    logic signed [14:0] exp;   // unbiased exponent of the leading one
    logic [52:0]        mant;  // normalised, bit 52 set unless zero
    logic               zero, inf, nan, snan;
  } fp_t;

  function automatic fp_t unpack(input logic [63:0] raw, input logic dbl);
    fp_t         r;
    logic [31:0] r32;
    logic [10:0] e;
    logic [51:0] f;
    logic        ez, eo;
    logic [52:0] m;
    int          lz;
    r32 = (&raw[63:32]) ? raw[31:0] : 32'h7fc0_0000;  // singles must be NaN-boxed
    if (dbl) begin
      r.sign = raw[63]; e = raw[62:52]; f = raw[51:0]; ez = raw[62:52] == '0; eo = &raw[62:52];
    end else begin
      r.sign = r32[31]; e = {3'b0, r32[30:23]}; f = {r32[22:0], 29'b0}; ez = r32[30:23] == '0; eo = &r32[30:23];
    end
    r.zero = ez && f == '0;
    r.inf  = eo && f == '0;
    r.nan  = eo && f != '0;
    r.snan = r.nan && !f[51];
    if (ez) begin
      m = {1'b0, f};
      lz = 0;
      for (int i = 0; i <= 52; i++) if (m[i]) lz = 52 - i;   // the highest set bit wins
      r.mant = m << lz;
      r.exp  = 15'(1 - (dbl ? 1023 : 127) - lz);
    end else begin
      r.mant = {1'b1, f};
      r.exp  = 15'(int'(e) - (dbl ? 1023 : 127));
    end
    return r;
  endfunction

  // Round a normalised value (mant[63] is the leading one, weight 2^exp) to the target format.
  function automatic logic [68:0] round_pack(input logic sign, input logic signed [14:0] exp,
                                              input logic [63:0] mant, input logic sticky,
                                              input logic dbl, input logic [2:0] rmode);
    int          emin, emax, bias, sh;
    logic        tiny_pre, st_d, rb, st, inc, rb_u, st_u, inc_u, carry_u, tiny, inexact, overflow, to_inf;
    logic [127:0] wide;
    logic [63:0] md;
    logic [52:0] kept, kept_u;
    logic [10:0] biased;
    logic [62:0] mag_d;
    logic [30:0] mag_s;
    logic [63:0] res;
    logic [4:0]  fl;
    emin = dbl ? -1022 : -126;
    emax = dbl ? 1023 : 127;
    bias = dbl ? 1023 : 127;
    tiny_pre = int'(exp) < emin;
    sh = tiny_pre ? emin - int'(exp) : 0;
    if (sh > 64) sh = 64;
    wide = {mant, 64'b0} >> sh;
    md   = wide[127:64];
    st_d = sticky | (|wide[63:0]);
    if (dbl) begin
      kept = md[63:11]; rb = md[10]; st = (|md[9:0]) | st_d;
      kept_u = mant[63:11]; rb_u = mant[10]; st_u = (|mant[9:0]) | sticky;
    end else begin
      kept = {29'b0, md[63:40]}; rb = md[39]; st = (|md[38:0]) | st_d;
      kept_u = {29'b0, mant[63:40]}; rb_u = mant[39]; st_u = (|mant[38:0]) | sticky;
    end
    unique case (rmode)
      RNE: begin inc = rb & (st | kept[0]);   inc_u = rb_u & (st_u | kept_u[0]); end
      RTZ: begin inc = 1'b0;                  inc_u = 1'b0; end
      RDN: begin inc = sign & (rb | st);      inc_u = sign & (rb_u | st_u); end
      RUP: begin inc = !sign & (rb | st);     inc_u = !sign & (rb_u | st_u); end
      default: begin inc = rb;                inc_u = rb_u; end
    endcase
    carry_u = inc_u && (dbl ? (&kept_u) : (&kept_u[23:0]));
    tiny    = tiny_pre && !(int'(exp) == emin - 1 && carry_u);
    inexact = rb | st;
    biased  = tiny_pre ? 11'd0 : 11'(int'(exp) + bias);
    // adding the increment to {exponent, fraction} lets a carry step the exponent naturally
    mag_d = {biased, kept[51:0]} + 63'(inc);
    mag_s = {biased[7:0], kept[22:0]} + 31'(inc);
    overflow = (int'(exp) > emax) || (dbl ? (&mag_d[62:52]) : (&mag_s[30:23]));
    to_inf = rmode == RNE || rmode == RMM || (rmode == RUP && !sign) || (rmode == RDN && sign);
    if (overflow) begin
      if (dbl) res = {sign, to_inf ? {11'h7ff, 52'b0} : {11'h7fe, {52{1'b1}}}};
      else     res = {32'hffff_ffff, sign, to_inf ? {8'hff, 23'b0} : {8'hfe, {23{1'b1}}}};
      fl = 5'b00101;
    end else begin
      res = dbl ? {sign, mag_d} : {32'hffff_ffff, sign, mag_s};
      fl  = {3'b000, tiny & inexact, inexact};
    end
    return {fl, res};
  endfunction

  // ------------------------------------------------------------------ decode
  logic        dbl;
  logic [4:0]  f5;
  logic [2:0]  f3;
  logic        op_fma_enc, op_fp;
  assign dbl = insn[25];
  assign f5  = insn[31:27];
  assign f3  = insn[14:12];
  assign op_fma_enc = insn[6:4] == 3'b100;        // fmadd, fmsub, fnmsub, fnmadd
  assign op_fp      = insn[6:0] == 7'b1010011;

  logic is_add, is_sub, is_mul, is_div, is_sqrt, is_sgnj, is_minmax, is_f2f, is_cmp, is_f2i, is_i2f,
        is_mvx_class, is_mvf, is_fma;
  assign is_add       = op_fp && f5 == 5'b00000;
  assign is_sub       = op_fp && f5 == 5'b00001;
  assign is_mul       = op_fp && f5 == 5'b00010;
  assign is_div       = op_fp && f5 == 5'b00011;
  assign is_sqrt      = op_fp && f5 == 5'b01011;
  assign is_sgnj      = op_fp && f5 == 5'b00100;
  assign is_minmax    = op_fp && f5 == 5'b00101;
  assign is_f2f       = op_fp && f5 == 5'b01000;
  assign is_cmp       = op_fp && f5 == 5'b10100;
  assign is_f2i       = op_fp && f5 == 5'b11000;
  assign is_i2f       = op_fp && f5 == 5'b11010;
  assign is_mvx_class = op_fp && f5 == 5'b11100;
  assign is_mvf       = op_fp && f5 == 5'b11110;
  assign is_fma       = op_fma_enc || is_add || is_sub || is_mul;

  // ------------------------------------------------------------------ operands
  fp_t A, B, C, Asrc;
  assign A    = unpack(a_raw, dbl);
  assign B    = unpack(b_raw, dbl);
  assign C    = unpack(c_raw, dbl);
  assign Asrc = unpack(a_raw, !dbl);   // fcvt.s.d / fcvt.d.s read the other format

  // FMA operand selection: result = (-1)^neg_p * (ma * mb) + (-1)^neg_c * mc
  fp_t  M1, M2, M3;
  logic p_sign, c_sign;
  always_comb begin
    M1 = A; M2 = B; M3 = C;
    if (is_add || is_sub) begin
      M2 = '0; M2.mant = 53'h10_0000_0000_0000;   // 1.0
      M3 = B;
    end
    p_sign = M1.sign ^ M2.sign ^ (op_fma_enc & insn[3]);          // fnmsub, fnmadd negate the product
    c_sign = M3.sign ^ (op_fma_enc ? insn[2] : is_sub);            // fmsub, fnmadd subtract c
    if (is_mul) begin
      M3 = '0; M3.zero = 1'b1;
      c_sign = p_sign;   // adding a like-signed zero leaves the product, including its zero sign
    end
  end
  logic p_zero, p_inf, fma_nv, fma_nan, fma_inf;
  assign p_zero  = M1.zero | M2.zero;
  assign p_inf   = M1.inf | M2.inf;
  assign fma_nv  = M1.snan | M2.snan | M3.snan | (M1.inf & M2.zero) | (M1.zero & M2.inf) |
                   (p_inf & !M1.nan & !M2.nan & M3.inf & (p_sign ^ c_sign));
  assign fma_nan = M1.nan | M2.nan | M3.nan | fma_nv;
  assign fma_inf = p_inf | M3.inf;

  // ------------------------------------------------------------------ combinational results
  logic [63:0] comb_res;
  logic [4:0]  comb_fl;

  // compare helpers on raw encodings
  logic [63:0] a_cmp, b_cmp;
  logic        a_lt_b, a_eq_b;
  always_comb begin
    a_cmp = dbl ? a_raw : {32'b0, (&a_raw[63:32]) ? a_raw[31:0] : 32'h7fc0_0000};
    b_cmp = dbl ? b_raw : {32'b0, (&b_raw[63:32]) ? b_raw[31:0] : 32'h7fc0_0000};
    a_eq_b = (a_cmp == b_cmp) || (A.zero && B.zero);
    if (A.sign != B.sign) a_lt_b = A.sign && !(A.zero && B.zero);
    else if (!A.sign)     a_lt_b = a_cmp[62:0] < b_cmp[62:0];
    else                  a_lt_b = a_cmp[62:0] > b_cmp[62:0];
  end

  // float to integer
  logic [127:0] f2i_wide;
  logic [63:0]  f2i_int;
  logic [64:0]  f2i_rnd;
  logic         f2i_rb, f2i_st, f2i_inc, f2i_unsigned, f2i_long, f2i_ovf;
  logic [63:0]  f2i_res;
  logic [4:0]   f2i_fl;
  logic         f2i_hi;
  logic [63:0]  f2i_v;
  int           f2i_sh;
  always_comb begin
    f2i_res = '0;
    f2i_fl  = '0;
    f2i_hi  = A.nan | !A.sign;   // NaN and positive overflow saturate high, negative low
    f2i_v   = '0;
    f2i_unsigned = insn[20];
    f2i_long     = insn[21];
    f2i_sh = 63 - int'(A.exp);
    if (f2i_sh > 127) f2i_sh = 127;
    if (f2i_sh < 0) f2i_sh = 0;
    f2i_wide = {A.mant, 11'b0, 64'b0} >> f2i_sh;
    f2i_int  = A.zero ? 64'b0 : f2i_wide[127:64];
    f2i_rb   = !A.zero & f2i_wide[63];
    f2i_st   = !A.zero & (|f2i_wide[62:0]);
    unique case (rm)
      RNE: f2i_inc = f2i_rb & (f2i_st | f2i_int[0]);
      RTZ: f2i_inc = 1'b0;
      RDN: f2i_inc = A.sign & (f2i_rb | f2i_st);
      RUP: f2i_inc = !A.sign & (f2i_rb | f2i_st);
      default: f2i_inc = f2i_rb;
    endcase
    f2i_rnd = {1'b0, f2i_int} + 65'(f2i_inc);
    // out of range for the destination type?
    f2i_ovf = A.nan | A.inf | (!A.zero && int'(A.exp) > 63);
    unique case ({f2i_long, f2i_unsigned})
      2'b00: f2i_ovf |= A.sign ? f2i_rnd > 65'h0_8000_0000 : f2i_rnd > 65'h0_7fff_ffff;
      2'b01: f2i_ovf |= A.sign ? f2i_rnd != 0 : f2i_rnd > 65'h0_ffff_ffff;
      2'b10: f2i_ovf |= A.sign ? f2i_rnd > 65'h0_8000_0000_0000_0000 : f2i_rnd > 65'h0_7fff_ffff_ffff_ffff;
      2'b11: f2i_ovf |= A.sign ? f2i_rnd != 0 : f2i_rnd[64];
    endcase
    if (f2i_ovf) begin
      unique case ({f2i_long, f2i_unsigned})
        2'b00: f2i_res = f2i_hi ? 64'h0000_0000_7fff_ffff : 64'hffff_ffff_8000_0000;
        2'b01: f2i_res = f2i_hi ? 64'hffff_ffff_ffff_ffff : 64'h0;
        2'b10: f2i_res = f2i_hi ? 64'h7fff_ffff_ffff_ffff : 64'h8000_0000_0000_0000;
        2'b11: f2i_res = f2i_hi ? 64'hffff_ffff_ffff_ffff : 64'h0;
      endcase
      f2i_fl = 5'b10000;
    end else begin
      f2i_v   = A.sign ? -f2i_rnd[63:0] : f2i_rnd[63:0];
      f2i_res = f2i_long ? f2i_v : {{32{f2i_v[31]}}, f2i_v[31:0]};
      f2i_fl  = {4'b0, f2i_rb | f2i_st};
    end
  end

  // classify
  logic [9:0] fclass;
  logic       a_sub;
  assign a_sub = dbl ? (a_raw[62:52] == '0 && !A.zero) : (a_cmp[30:23] == '0 && !A.zero);
  assign fclass = {A.nan & !A.snan, A.snan, !A.sign & A.inf, !A.sign & !A.inf & !A.nan & !A.zero & !a_sub,
                   !A.sign & a_sub, !A.sign & A.zero, A.sign & A.zero, A.sign & a_sub,
                   A.sign & !A.inf & !A.nan & !A.zero & !a_sub, A.sign & A.inf};

  logic comb_op;   // finishes in the start cycle
  // scratch values of the block below, given a value on every path so that none is a latch
  logic cb_s, cb_pick_a, cb_any_nan;
  always_comb begin
    comb_res = '0;
    comb_fl  = '0;
    comb_op  = 1'b1;
    cb_s = 1'b0; cb_pick_a = 1'b0; cb_any_nan = 1'b0;
    if (is_sgnj) begin
      cb_s = f3[1] ? A.sign ^ B.sign : f3[0] ? !B.sign : B.sign;
      comb_res = dbl ? {cb_s, a_raw[62:0]} : {32'hffff_ffff, cb_s, a_cmp[30:0]};
    end else if (is_minmax) begin
      comb_fl = {A.snan | B.snan, 4'b0};
      if (A.nan && B.nan) comb_res = dbl ? QNAN_D : QNAN_S;
      else begin
        if (A.nan) cb_pick_a = 1'b0;
        else if (B.nan) cb_pick_a = 1'b1;
        else cb_pick_a = f3[0] ? !a_lt_b && !(A.zero && B.zero && A.sign) : a_lt_b || (A.zero && B.zero && A.sign);
        comb_res = dbl ? (cb_pick_a ? a_raw : b_raw) : {32'hffff_ffff, cb_pick_a ? a_cmp[31:0] : b_cmp[31:0]};
      end
    end else if (is_cmp) begin
      cb_any_nan = A.nan | B.nan;
      unique case (f3[1:0])
        2'b10:   begin comb_res = 64'(!cb_any_nan && a_eq_b);             comb_fl = {A.snan | B.snan, 4'b0}; end
        2'b01:   begin comb_res = 64'(!cb_any_nan && a_lt_b);             comb_fl = {cb_any_nan, 4'b0}; end
        default: begin comb_res = 64'(!cb_any_nan && (a_lt_b || a_eq_b)); comb_fl = {cb_any_nan, 4'b0}; end
      endcase
    end else if (is_f2i) begin
      comb_res = f2i_res;
      comb_fl  = f2i_fl;
    end else if (is_mvx_class) begin
      if (f3[0]) comb_res = {54'b0, fclass};
      else       comb_res = dbl ? a_raw : {{32{a_raw[31]}}, a_raw[31:0]};
    end else if (is_mvf) begin
      comb_res = dbl ? x_in : {32'hffff_ffff, x_in[31:0]};
    end else if (is_fma && (fma_nan || fma_inf)) begin
      comb_fl = {fma_nv, 4'b0};
      if (fma_nan) comb_res = dbl ? QNAN_D : QNAN_S;
      else begin
        cb_s = p_inf ? p_sign : c_sign;
        comb_res = dbl ? {cb_s, 11'h7ff, 52'b0} : {32'hffff_ffff, cb_s, 8'hff, 23'b0};
      end
    end else if (is_div && (A.nan || B.nan || A.inf || B.inf || A.zero || B.zero)) begin
      cb_s = A.sign ^ B.sign;
      if (A.nan || B.nan || (A.inf && B.inf) || (A.zero && B.zero)) begin
        comb_res = dbl ? QNAN_D : QNAN_S;
        comb_fl  = {A.snan | B.snan | (A.inf & B.inf) | (A.zero & B.zero), 4'b0};
      end else if (A.inf || B.zero) begin
        comb_res = dbl ? {cb_s, 11'h7ff, 52'b0} : {32'hffff_ffff, cb_s, 8'hff, 23'b0};
        comb_fl  = {1'b0, B.zero & !A.inf, 3'b0};
      end else begin
        comb_res = dbl ? {cb_s, 63'b0} : {32'hffff_ffff, cb_s, 31'b0};
      end
    end else if (is_sqrt && (A.nan || A.zero || A.inf || A.sign)) begin
      if (A.nan || (A.sign && !A.zero)) begin
        comb_res = dbl ? QNAN_D : QNAN_S;
        comb_fl  = {A.snan | !A.nan, 4'b0};
      end else begin
        comb_res = dbl ? a_raw : {32'hffff_ffff, a_cmp[31:0]};   // +-0 and +inf map to themselves
      end
    end else if (is_f2f && (Asrc.nan || Asrc.inf || Asrc.zero)) begin
      comb_fl = {Asrc.snan, 4'b0};
      if (Asrc.nan)      comb_res = dbl ? QNAN_D : QNAN_S;
      else if (Asrc.inf) comb_res = dbl ? {Asrc.sign, 11'h7ff, 52'b0} : {32'hffff_ffff, Asrc.sign, 8'hff, 23'b0};
      else               comb_res = dbl ? {Asrc.sign, 63'b0} : {32'hffff_ffff, Asrc.sign, 31'b0};
    end else if (is_i2f && (insn[21] ? x_in == '0 : x_in[31:0] == '0)) begin
      comb_res = dbl ? 64'b0 : {32'hffff_ffff, 32'b0};
    end else begin
      comb_op = 1'b0;
    end
  end

  // ------------------------------------------------------------------ sequenced datapath
  typedef enum logic [2:0] {S_IDLE, S_ADD, S_DIV, S_SQRT, S_NORM, S_ROUND} state_e;
  state_e state;

  logic [105:0]       prod;
  logic [164:0]       int_q;    // exact magnitude
  logic signed [14:0] base_q;   // value = int_q * 2^base_q
  logic               sign_q;
  logic [63:0]        n_mant;
  logic               n_sticky, n_zero;
  logic signed [14:0] n_exp;
  logic [6:0]         cnt;
  logic [57:0]        dv_q;
  logic [55:0]        dv_r;
  logic [111:0]       sq_n;
  logic [59:0]        sq_rem;
  logic [55:0]        sq_root;

  // FMA alignment and addition (evaluated in S_ADD)
  logic signed [14:0] ep, fma_d;
  logic               fma_clamp, fma_sub, fma_c_big;
  logic [7:0]         fma_dcl;
  logic [325:0]       c_sh;
  logic [163:0]       c_fr, p_fr;
  logic [164:0]       fma_mag;
  logic               fma_sign;
  always_comb begin
    ep        = M1.exp + M2.exp;
    fma_d     = ep - M3.exp + 15'sd56;
    fma_clamp = p_zero || (!M3.zero && fma_d < 0);
    fma_dcl   = fma_clamp ? 8'd0 : (fma_d > 15'sd163) ? 8'd163 : fma_d[7:0];
    c_sh      = {M3.zero ? 53'b0 : M3.mant, 110'b0, 163'b0} >> fma_dcl;
    c_fr      = {1'b0, c_sh[325:164], c_sh[163] | (|c_sh[162:0])};
    p_fr      = {56'b0, p_zero ? 106'b0 : prod, 2'b0};
    fma_sub   = p_sign ^ c_sign;
    fma_c_big = c_fr > p_fr;
    if (!fma_sub)       begin fma_mag = {1'b0, p_fr} + {1'b0, c_fr}; fma_sign = p_sign; end
    else if (fma_c_big) begin fma_mag = {1'b0, c_fr} - {1'b0, p_fr}; fma_sign = c_sign; end
    else                begin fma_mag = {1'b0, p_fr} - {1'b0, c_fr}; fma_sign = p_sign; end
    if (fma_mag == '0) fma_sign = fma_sub ? rm == RDN : p_sign;
  end

  // integer to float magnitude
  logic [63:0] i2f_val, i2f_mag;
  logic        i2f_neg;
  always_comb begin
    unique case (insn[21:20])
      2'b00:   i2f_val = {{32{x_in[31]}}, x_in[31:0]};
      2'b01:   i2f_val = {32'b0, x_in[31:0]};
      default: i2f_val = x_in;
    endcase
    i2f_neg = !insn[20] && i2f_val[63];
    i2f_mag = i2f_neg ? -i2f_val : i2f_val;
  end

  // normalise (evaluated in S_NORM)
  int           nz;
  logic [164:0] n_shifted;
  always_comb begin
    nz = 165;
    for (int i = 0; i <= 164; i++) if (int_q[i]) nz = 164 - i;   // the highest set bit wins
    n_shifted = int_q << (nz == 165 ? 0 : nz);
  end

  // divide and square-root steps
  logic [56:0] dv_sub;
  logic [59:0] sq_t, sq_trial;
  assign dv_sub   = {1'b0, dv_r} - {4'b0, B.mant};
  assign sq_t     = {sq_rem[57:0], sq_n[111:110]};
  assign sq_trial = {2'b0, sq_root, 2'b01};

  assign busy = state != S_IDLE;

  logic [68:0] rp;
  assign rp = round_pack(sign_q, n_exp, n_mant, n_sticky, dbl, rm);

  always_comb begin
    done = 1'b0; result = '0; flags = '0;
    if (state == S_IDLE && start && comb_op) begin
      done = 1'b1; result = comb_res; flags = comb_fl;
    end else if (state == S_ROUND) begin
      done = 1'b1;
      if (n_zero) result = dbl ? {sign_q, 63'b0} : {32'hffff_ffff, sign_q, 31'b0};
      else begin result = rp[63:0]; flags = rp[68:64]; end
    end
  end

  // The mantissa product, in a block of its own with a synchronous reset, so that the register can
  // be the output register of an FPGA's multiplier block (which has no asynchronous reset).
  always_ff @(posedge clk) begin
    if (!rst_n) prod <= '0;
    else if (state == S_IDLE && start && !comb_op && is_fma) prod <= M1.mant * M2.mant;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      int_q <= '0; base_q <= '0; sign_q <= 1'b0;
      n_mant <= '0; n_sticky <= 1'b0; n_zero <= 1'b0; n_exp <= '0;
      cnt <= '0; dv_q <= '0; dv_r <= '0; sq_n <= '0; sq_rem <= '0; sq_root <= '0;
    end else begin
      unique case (state)
        S_IDLE: if (start && !comb_op) begin
          if (is_fma) begin
            state <= S_ADD;        // the product is registered below
          end else if (is_div) begin
            dv_r <= {3'b0, A.mant}; dv_q <= '0; cnt <= 7'd58;
            sign_q <= A.sign ^ B.sign;
            state <= S_DIV;
          end else if (is_sqrt) begin
            sq_n <= A.exp[0] ? {A.mant, 1'b0, 58'b0} : {1'b0, A.mant, 58'b0};
            sq_rem <= '0; sq_root <= '0; cnt <= 7'd56;
            sign_q <= 1'b0;
            state <= S_SQRT;
          end else if (is_i2f) begin
            int_q <= {101'b0, i2f_mag}; base_q <= '0; sign_q <= i2f_neg;
            state <= S_NORM;
          end else begin  // float to float
            int_q <= {112'b0, Asrc.mant}; base_q <= Asrc.exp - 15'sd52; sign_q <= Asrc.sign;
            state <= S_NORM;
          end
        end
        S_ADD: begin
          int_q  <= fma_mag;
          base_q <= fma_clamp ? M3.exp - 15'sd162 : ep - 15'sd106;
          sign_q <= fma_sign;
          state  <= S_NORM;
        end
        S_DIV: begin
          if (cnt == 0) begin
            int_q  <= {106'b0, dv_q, dv_r != '0};
            base_q <= A.exp - B.exp - 15'sd58;
            state  <= S_NORM;
          end else begin
            cnt <= cnt - 7'd1;
            if (!dv_sub[56]) begin dv_r <= {dv_sub[54:0], 1'b0}; dv_q <= {dv_q[56:0], 1'b1}; end
            else             begin dv_r <= {dv_r[54:0], 1'b0};   dv_q <= {dv_q[56:0], 1'b0}; end
          end
        end
        S_SQRT: begin
          if (cnt == 0) begin
            int_q  <= {108'b0, sq_root, sq_rem != '0};
            base_q <= $signed({A.exp[14], A.exp[14:1]}) - 15'sd56;   // floor(exp / 2) - 56
            state  <= S_NORM;
          end else begin
            cnt  <= cnt - 7'd1;
            sq_n <= {sq_n[109:0], 2'b0};
            if (sq_t >= sq_trial) begin sq_rem <= sq_t - sq_trial; sq_root <= {sq_root[54:0], 1'b1}; end
            else                  begin sq_rem <= sq_t;            sq_root <= {sq_root[54:0], 1'b0}; end
          end
        end
        S_NORM: begin
          n_zero   <= nz == 165;
          n_mant   <= n_shifted[164:101];
          n_sticky <= |n_shifted[100:0];
          n_exp    <= base_q + 15'(164 - nz);
          state    <= S_ROUND;
        end
        S_ROUND: if (accept) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
