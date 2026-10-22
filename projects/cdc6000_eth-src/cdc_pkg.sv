// Arithmetic of the CDC 6000 series: 60 bit and 18 bit ones-complement integers, and the 60 bit floating point
// format (1 sign, 11 exponent, 48 coefficient bits; the negative of a number is the complement of the whole word).
// Every function is a transcription of the same function in host/cdcemu.c, which is the reference model.
package cdc_pkg;

  localparam logic [59:0] M60 = 60'hFFFFFFFFFFFFFFF;

  // ---------------- 18 bit (B and A registers, addresses) ----------------
  // x + (-x) is +0 on this machine; only -0 + -0 stays -0
  function automatic logic [17:0] add18(input logic [17:0] a, input logic [17:0] b);
    logic [18:0] s;
    s = {1'b0, a} + {1'b0, b};
    if (s[18]) s = {1'b0, s[17:0]} + 19'd1;
    if (s[17:0] == 18'h3FFFF && !(a == 18'h3FFFF && b == 18'h3FFFF)) s[17:0] = 18'd0;
    add18 = s[17:0];
  endfunction
  function automatic logic [17:0] neg18(input logic [17:0] a);
    neg18 = ~a;
  endfunction
  // value of a ones-complement number: -0 is 0
  function automatic logic signed [18:0] sb18(input logic [17:0] a);
    sb18 = a[17] ? -$signed({1'b0, ~a}) : $signed({1'b0, a});
  endfunction
  function automatic logic [59:0] sx18(input logic [17:0] a);
    sx18 = {{42{a[17]}}, a};
  endfunction

  // ---------------- 60 bit ----------------
  function automatic logic [59:0] add60(input logic [59:0] a, input logic [59:0] b);
    logic [60:0] s;
    s = {1'b0, a} + {1'b0, b};
    if (s[60]) s = {1'b0, s[59:0]} + 61'd1;
    if (s[59:0] == M60 && !(a == M60 && b == M60)) s[59:0] = 60'd0;
    add60 = s[59:0];
  endfunction

  function automatic logic [59:0] rotl60(input logic [59:0] x, input logic [5:0] n);
    logic [5:0] r;
    logic [119:0] t;
    r = (n >= 6'd60) ? n - 6'd60 : n;
    t = ({60'd0, x} << r);
    rotl60 = t[59:0] | t[119:60];
  endfunction

  function automatic logic [59:0] sar60(input logic [59:0] x, input logic [5:0] n);
    logic signed [59:0] s;
    s = x;
    if (n >= 6'd60) sar60 = {60{x[59]}};
    else sar60 = 60'(s >>> n);
  endfunction

  function automatic logic [59:0] mask43(input logic [5:0] n);
    logic [59:0] t;
    if (n == 0) mask43 = 60'd0;
    else if (n >= 6'd60) mask43 = M60;
    else begin
      t = M60 << (6'd60 - n);
      mask43 = t;
    end
  endfunction

  function automatic logic [59:0] popcount60(input logic [59:0] x);
    logic [6:0] c;
    c = 0;
    for (int i = 0; i < 60; i++) c = c + {6'd0, x[i]};
    popcount60 = {53'd0, c};
  endfunction

  // 22/23: the shift count of a B register: low 6 bits, direction from the sign bit
  function automatic logic [5:0] shcount(input logic [17:0] b);
    shcount = b[17] ? ~b[5:0] : b[5:0];
  endfunction

  // ---------------- floating point ----------------
  typedef struct packed {
    logic              neg;
    logic signed [15:0] e;     // value = c * 2**e
    logic [47:0]       c;
  } fl_t;

  function automatic fl_t funpack(input logic [59:0] w);
    fl_t f;
    logic [59:0] v;
    f.neg = w[59];
    v = f.neg ? ~w : w;
    f.e = $signed({4'b0, v[59:48]}) - 16'sd1024;
    f.c = v[47:0];
    funpack = f;
  endfunction

  function automatic logic [59:0] fpack(input logic neg, input logic signed [15:0] e, input logic [47:0] c);
    logic [11:0] ef;
    logic [59:0] w;
    ef = 12'(e + 16'sd1024);
    w = {ef, c};
    fpack = neg ? ~w : w;
  endfunction

  // ---- floating results are produced in two steps: a *prep* function turns the operands into an unnormalised magnitude
  // (sign, m * 2**e, or a ready result), and one shared fnorm normalises, rounds and packs it.
  localparam int NW = 112;
  typedef struct packed {
    logic              zero;      // the result is +0
    logic              neg;
    logic [NW-1:0]     m;
    logic signed [15:0] e;
  } nrm_t;

  function automatic int msbn(input logic [NW-1:0] m);
    int p;
    p = 0;
    for (int i = 0; i < NW; i++) if (m[i]) p = i;
    msbn = p;
  endfunction

  // normalise a magnitude m * 2**e to 48 bits (truncating or rounding) and pack it
  function automatic logic [59:0] fnorm(input nrm_t n, input logic round);
    logic [NW-1:0] m;
    int e, p, sh;
    m = n.m; e = int'(n.e);
    if (n.zero || m == 0) fnorm = 60'd0;
    else begin
      p = msbn(m);
      sh = p - 47;
      if (sh > 0) begin
        if (round) m = m + (112'd1 << (sh - 1));
        m = m >> sh;
        e = e + sh;
        if (m[48]) begin m = m >> 1; e = e + 1; end
      end else if (sh < 0) begin
        m = m << (-sh);
        e = e + sh;
      end
      if (e + 1024 <= 0) fnorm = 60'd0;                                  // underflow
      else if (e + 1024 >= 'h7ff) fnorm = n.neg ? ~{12'h7ff, 48'd0} : {12'h7ff, 48'd0};   // overflow: infinite
      else fnorm = fpack(n.neg, 16'(e), m[47:0]);
    end
  endfunction

  function automatic nrm_t add_prep(input logic [59:0] a, input logic [59:0] b, input logic sub);
    fl_t x, y, t;
    int d;
    logic signed [NW:0] sx, sy, s;
    nrm_t r;
    x = funpack(a); y = funpack(b);
    if (sub) y.neg = !y.neg;
    r.zero = 1'b0; r.neg = 1'b0; r.m = '0; r.e = 16'sd0;
    if (x.c == 0) begin
      if (y.c == 0) r.zero = 1'b1;
      else begin r.neg = y.neg; r.m = NW'(y.c); r.e = y.e; end
    end else if (y.c == 0) begin
      r.neg = x.neg; r.m = NW'(x.c); r.e = x.e;
    end else begin
      if (x.e < y.e) begin t = x; x = y; y = t; end
      d = int'(x.e) - int'(y.e);
      if (d > 60) begin r.neg = x.neg; r.m = NW'(x.c); r.e = x.e; end
      else begin
        sx = $signed({{(NW+1-48){1'b0}}, x.c}) <<< d;
        if (x.neg) sx = -sx;
        sy = $signed({{(NW+1-48){1'b0}}, y.c});
        if (y.neg) sy = -sy;
        s = sx + sy;
        r.e = y.e;
        if (s == 0) r.zero = 1'b1;
        else if (s < 0) begin r.neg = 1'b1; r.m = NW'(-s); end
        else r.m = NW'(s);
      end
    end
    add_prep = r;
  endfunction

  function automatic nrm_t mul_prep(input logic [59:0] a, input logic [59:0] b, input logic [95:0] p);
    fl_t x, y;
    nrm_t r;
    x = funpack(a); y = funpack(b);
    r.zero = 1'b0; r.neg = x.neg ^ y.neg; r.m = NW'(p); r.e = 16'(int'(x.e) + int'(y.e));
    mul_prep = r;
  endfunction

  // DX*: the low half of the product; with both exponents zero (two integers) this is the integer product
  function automatic logic [59:0] dmul_from(input logic [59:0] a, input logic [59:0] b, input logic [95:0] p);
    fl_t x, y;
    logic [95:0] lo;
    logic neg;
    int pp, sh;
    x = funpack(a); y = funpack(b);
    neg = x.neg ^ y.neg;
    if (x.e == -16'sd1024 && y.e == -16'sd1024)
      dmul_from = neg ? ~{12'd0, p[47:0]} : {12'd0, p[47:0]};
    else if (p == 0) dmul_from = 60'd0;
    else begin
      pp = msbn(NW'(p));
      sh = pp - 47; if (sh < 0) sh = 0;
      lo = p & ((96'd1 << sh) - 96'd1);
      dmul_from = fpack(neg, 16'(int'(x.e) + int'(y.e)), lo[47:0]);
    end
  endfunction

  // the same operations in one piece, for tests
  function automatic logic [59:0] fadd(input logic [59:0] a, input logic [59:0] b, input logic sub, input logic round);
    fadd = fnorm(add_prep(a, b, sub), round);
  endfunction
  function automatic logic [59:0] fmul(input logic [59:0] a, input logic [59:0] b, input logic round);
    logic [95:0] p;
    fl_t x, y;
    x = funpack(a); y = funpack(b);
    p = {48'd0, x.c} * {48'd0, y.c};
    fmul = fnorm(mul_prep(a, b, p), round);
  endfunction
  function automatic logic [59:0] dmul(input logic [59:0] a, input logic [59:0] b);
    logic [95:0] p;
    fl_t x, y;
    x = funpack(a); y = funpack(b);
    p = {48'd0, x.c} * {48'd0, y.c};
    dmul = dmul_from(a, b, p);
  endfunction

  // ---- the same floating add and normalise cut into stages for a pipelined unit (cdc6000_sb): each stage is short enough for a
  // clock of 100 MHz and more.  fn_s3(fn_s2(fn_s1(fa_s2(fa_s1(a, b, sub))), round)) = fnorm(add_prep(a, b, sub), round).
  typedef struct packed {
    logic [1:0]        kind;          // 0: add the two, 1: the result is c0 alone, 2: the result is zero
    logic              neg0;
    logic [47:0]       c0;
    logic signed [15:0] e0;
    logic              xn, yn;
    logic [47:0]       xc, yc;
    logic [6:0]        d;
    logic signed [15:0] ye;
  } fa1_t;

  function automatic fa1_t fa_s1(input logic [59:0] a, input logic [59:0] b, input logic sub);
    fa1_t r;
    fl_t x, y, t;
    int d;
    x = funpack(a); y = funpack(b);
    if (sub) y.neg = !y.neg;
    r = '0;
    if (x.c == 0) begin
      if (y.c == 0) r.kind = 2'd2;
      else begin r.kind = 2'd1; r.neg0 = y.neg; r.c0 = y.c; r.e0 = y.e; end
    end else if (y.c == 0) begin
      r.kind = 2'd1; r.neg0 = x.neg; r.c0 = x.c; r.e0 = x.e;
    end else begin
      if (x.e < y.e) begin t = x; x = y; y = t; end
      d = int'(x.e) - int'(y.e);
      if (d > 60) begin r.kind = 2'd1; r.neg0 = x.neg; r.c0 = x.c; r.e0 = x.e; end
      else begin r.kind = 2'd0; r.xn = x.neg; r.xc = x.c; r.yn = y.neg; r.yc = y.c; r.d = 7'(d); r.ye = y.e; end
    end
    fa_s1 = r;
  endfunction

  function automatic nrm_t fa_s2(input fa1_t s);
    nrm_t r;
    logic [NW-1:0] sx, sy;
    r.zero = 1'b0; r.neg = 1'b0; r.m = '0; r.e = 16'sd0;
    if (s.kind == 2'd2) r.zero = 1'b1;
    else if (s.kind == 2'd1) begin r.neg = s.neg0; r.m = NW'(s.c0); r.e = s.e0; end
    else begin
      sx = NW'(s.xc) << s.d; sy = NW'(s.yc);
      r.e = s.ye;
      if (s.xn == s.yn) begin r.m = sx + sy; r.neg = s.xn; end
      else if (sx >= sy) begin r.m = sx - sy; r.neg = s.xn; end
      else begin r.m = sy - sx; r.neg = s.yn; end
      if (r.m == 0) begin r.zero = 1'b1; r.neg = 1'b0; end
    end
    fa_s2 = r;
  endfunction

  typedef struct packed {
    logic              zero, neg, round;
    logic [NW-1:0]     m;
    logic signed [15:0] e;
    logic [6:0]        p;             // the position of the top bit
  } fn1_t;
  typedef struct packed {
    logic              zero, neg;
    logic [47:0]       c;
    logic signed [15:0] e;
  } fn2_t;

  function automatic fn1_t fn_s1(input nrm_t n, input logic round);
    fn1_t r;
    r.zero = n.zero || (n.m == '0); r.neg = n.neg; r.round = round; r.m = n.m; r.e = n.e; r.p = 7'(msbn(n.m));
    fn_s1 = r;
  endfunction

  function automatic fn2_t fn_s2(input fn1_t s);
    fn2_t r;
    logic [NW-1:0] m;
    int e, sh;
    m = s.m; e = int'(s.e); sh = int'(s.p) - 47;
    if (sh > 0) begin
      if (s.round) m = m + (112'd1 << (sh - 1));
      m = m >> sh;
      e = e + sh;
      if (m[48]) begin m = m >> 1; e = e + 1; end
    end else if (sh < 0) begin
      m = m << (-sh);
      e = e + sh;
    end
    r.zero = s.zero; r.neg = s.neg; r.c = m[47:0]; r.e = 16'(e);
    fn_s2 = r;
  endfunction

  function automatic logic [59:0] fn_s3(input fn2_t s);
    int e;
    e = int'(s.e);
    if (s.zero) fn_s3 = 60'd0;
    else if (e + 1024 <= 0) fn_s3 = 60'd0;
    else if (e + 1024 >= 'h7ff) fn_s3 = s.neg ? ~{12'h7ff, 48'd0} : {12'h7ff, 48'd0};
    else fn_s3 = fpack(s.neg, 16'(e), s.c);
  endfunction

  // ---- 60 bit ones-complement add in two stages: both sums, then the choice and the correction of an all-ones result
  typedef struct packed { logic c0, bothones; logic [59:0] s0, s1; } add1_t;
  function automatic add1_t add_s1(input logic [59:0] a, input logic [59:0] b);
    add1_t r;
    logic [60:0] t;
    t = {1'b0, a} + {1'b0, b};
    r.c0 = t[60]; r.s0 = t[59:0]; r.s1 = a + b + 60'd1; r.bothones = (a == M60) && (b == M60);
    add_s1 = r;
  endfunction
  function automatic logic [59:0] add_s2(input add1_t t);
    logic [59:0] r;
    r = t.c0 ? t.s1 : t.s0;
    if (r == M60 && !t.bothones) r = 60'd0;
    add_s2 = r;
  endfunction

  // population count as a tree (a serial sum is a hundred logic levels)
  function automatic logic [23:0] pop_s1(input logic [59:0] x);     // six counts of ten bits
    logic [23:0] r;
    for (int g = 0; g < 6; g++) begin
      logic [3:0] c;
      c = 4'd0;
      for (int i = 0; i < 10; i++) c = c + {3'd0, x[10*g + i]};
      r[4*g +: 4] = c;
    end
    pop_s1 = r;
  endfunction
  function automatic logic [59:0] pop_s2(input logic [23:0] r);
    logic [6:0] c;
    c = 7'd0;
    for (int g = 0; g < 6; g++) c = c + {3'd0, r[4*g +: 4]};
    pop_s2 = {53'd0, c};
  endfunction

  // normalise (NX, ZX) in two stages: the count of leading zeros, then the shift
  typedef struct packed { logic zero, neg; logic [47:0] c; logic signed [15:0] e; logic [5:0] n; } nx1_t;
  function automatic nx1_t nx_s1(input logic [59:0] w);
    nx1_t r;
    fl_t f;
    f = funpack(w);
    r.zero = (f.c == 0); r.neg = f.neg; r.c = f.c; r.e = f.e; r.n = 6'(clz48(f.c));
    nx_s1 = r;
  endfunction
  function automatic logic [59:0] nx_s2(input nx1_t r);
    logic [47:0] c;
    logic signed [15:0] e;
    if (r.zero) nx_s2 = 60'd0;
    else begin
      c = r.c << r.n; e = r.e - 16'(r.n);
      nx_s2 = fpack(r.neg, e, c);
    end
  endfunction

  // number of leading zeros of a 48 bit coefficient
  function automatic int clz48(input logic [47:0] c);
    int n;
    n = 48;
    for (int i = 0; i < 48; i++) if (c[i]) n = 47 - i;
    clz48 = n;
  endfunction

  // NX / ZX / UX / PX
  function automatic logic [59:0] nx_result(input logic [59:0] w);
    fl_t f; int n; logic [47:0] c; logic signed [15:0] e;
    f = funpack(w);
    if (f.c == 0) nx_result = 60'd0;
    else begin
      n = clz48(f.c);
      c = f.c << n;
      e = f.e - 16'(n);
      nx_result = fpack(f.neg, e, c);
    end
  endfunction
  function automatic logic [17:0] nx_count(input logic [59:0] w);
    fl_t f;
    f = funpack(w);
    nx_count = (f.c == 0) ? 18'd0 : 18'(clz48(f.c));
  endfunction

  function automatic logic [59:0] ux_coef(input logic [59:0] w);
    fl_t f;
    f = funpack(w);
    ux_coef = f.neg ? ~{12'd0, f.c} : {12'd0, f.c};
  endfunction
  function automatic logic [17:0] ux_exp(input logic [59:0] w);
    fl_t f; logic signed [18:0] e;
    f = funpack(w);
    e = 19'(f.e);
    ux_exp = (e < 0) ? ~18'(-e) : 18'(e);
  endfunction

  function automatic logic [59:0] px_result(input logic [59:0] w, input logic [17:0] bj);
    logic neg; logic [59:0] v; logic [47:0] c; logic signed [15:0] e; logic [59:0] r;
    neg = w[59];
    v = neg ? ~w : w;
    c = v[47:0];
    e = 16'(sb18(bj));
    px_result = fpack(neg, e, c);
  endfunction

endpackage
