// A CDC 6000 series central processor with an instruction stack, in-order issue, a scoreboard and several functional units.
//
// The instruction set and every result are those of cdc6000_core.sv (the reference RTL) and host/cdcemu.c (the reference model); this
// file is a different organisation of the same machine, described in rtl/SUPERSCALAR.md.  The organisation follows the one in the
// open literature for this machine (J. E. Thornton, "Design of a Computer: the Control Data 6600", 1970):
//
//   instruction stack  ->  decode register  ->  issue  ->  functional units (boolean, shift, long add, floating add, multiply,
//                                                          divide, increment x NINC, branch)  ->  result buses  ->  registers
//
// * Issue is in order, one instruction a cycle.  An instruction issues if its unit is free and its destination registers are not
//   reserved by an unfinished instruction.  Issue then goes on to the next instruction.
// * The instruction waits in its unit for operands that are not yet written.  A reservation names the instruction that will write the
//   register (a tag); an operand that is reserved is taken from the result bus when the tag appears there.  An operand that is not
//   reserved is read at issue.  (The original reads the registers from the unit when both operands are ready and holds a result back
//   until earlier readers have read; here the value is captured, which gives the same results without that check.)
// * A-register instructions are the memory instructions: SA1-SA5 load X1-X5, SA6-SA7 store X6-X7.  The address comes from an increment
//   unit; the reference goes through a queue that keeps program order, so memory needs no further checking.
// * An unconditional branch to a known place redirects the instruction fetch at decode; a conditional branch whose operands are
//   there is decided at issue.  One that must wait goes to the branch unit, and (SPEC) issue goes on along the way decode guessed:
//   what is issued meanwhile is marked speculative.  If the guess was right the marks are dropped; if it was wrong, the marked
//   entries in the units, the stages of the pipelined units, the memory queue, the tags and the reservations are cleared and the
//   fetch is redirected.  A speculative store, I/O access or return jump waits at the head of the memory queue for the branch; a
//   speculative load from memory goes ahead.  The registers are copied when the branch goes into the unit; results of instructions
//   before the branch go into both copies, speculative results into the live one only, and a wrong guess brings the copy back.  A
//   speculative instruction may take over a register that an instruction before the branch still has to write: that producer's
//   tag is kept (sh_t), its result then goes into the copy, and it is the reservation again if the guess was wrong.
// * DUAL: two instructions a cycle.  Decode looks at the word and the one after it; the second instruction of a pair takes what
//   the first writes as a tag, uses another unit (a second increment unit, or a branch decided at issue), and is speculative if
//   the first is a branch that goes to the branch unit.
// * Exceptions (PS, a 30 bit instruction in the last parcel of a word) stop the machine once everything before has finished.
//
// The memory has two read ports: the instruction port fetches whole words into the instruction stack, the data port serves the
// loads and stores.  EXT_MEM=1: the memory is outside (fpga/vc707-eth/genmem.py makes it); otherwise it is an array in here.
module cdc6000_sb #(
    parameter int MEM_AW = 17,
    parameter MEM_INIT = "",
    parameter bit EXT_MEM = 1'b0,
    parameter int NSK = 8,            // words in the instruction stack
    parameter int NINC = 2,           // address increment units
    parameter int NBOOL = 2,          // boolean units
    parameter int LAT_BOOL = 1,       // result latency: cycles from the start of execution to the result on the bus (the units that are
    parameter int LAT_SHIFT = 2,      // cut into stages have a fixed one: long add 2, floating add 5, multiply 7, divide 3 after the
    parameter int LAT_INC = 1,        // last quotient bit, normalise/pack/count 3)
    parameter int MEMLAT = 1,         // 1: the word read is on the bus the cycle after the request; 2: one register more
    parameter int HALT_WAIT = 80,     // cycles that older instructions get to finish after the store that halts
    parameter int BHT_AW = 9,         // the branch history table: 2 bit counters, 2**BHT_AW of them (decode follows the guess; nothing executes on a guess)
    parameter bit AGEN = 1'b1,        // work out the address of a load or store at issue when the operands are there
    parameter bit RELAX_WAW = 1'b1,   // 1: an instruction may issue while its destination is reserved (the newer tag takes over); 0: it waits, as on the original
    parameter bit SPEC = 1'b1,        // 1: issue goes on past a conditional branch that waits in the branch unit, on the guess decode made; what was
                                      // issued after it is undone if the guess was wrong.  0: issue waits for the branch, as on the original
    parameter bit DUAL = 1'b1         // 1: two instructions a cycle (decode and issue); 0: one
) (
    input logic clk,
    input logic reset,

    // instruction port and data port of an outside memory
    output logic [MEM_AW-1:0] ext_iaddr,
    input  logic [59:0]       ext_irdata,
    output logic [MEM_AW-1:0] ext_addr,
    output logic              ext_we,
    output logic [59:0]       ext_wdata,
    input  logic [59:0]       ext_rdata,

    input  logic                load_we,
    input  logic [MEM_AW-1:0]   load_addr,
    input  logic [59:0]         load_data,

    input  logic        rx_valid,
    input  logic [5:0]  rx_char,
    input  logic        rx_eof,
    output logic        rx_take,

    output logic        tx_valid,
    output logic [5:0]  tx_char,
    input  logic        tx_ready,

    output logic        fo_valid,
    output logic [59:0] fo_name,
    output logic [59:0] fo_word,
    input  logic        fo_ready,

    output logic        dev_req,
    output logic        dev_we,
    output logic [12:0] dev_off,
    output logic [59:0] dev_wdata,
    input  logic        dev_ack,
    input  logic [59:0] dev_rdata,

    output logic        halted,
    output logic        fault,

    output logic [17:0]  dbg_pc,
    output logic [63:0]  icount,
    output logic [479:0] dbg_x,
    output logic [143:0] dbg_a,
    output logic [143:0] dbg_b,
    output logic [511:0] dbg_perf       // 16 counters of 32 bits: see the always_ff below
);
  import cdc_pkg::*;

  localparam int U_BR = 0, U_BOOL = 1, U_SHIFT = 2, U_LADD = 3, U_FADD = 4, U_MUL = 5, U_DIV = 6, U_NORM = 7, U_INC0 = 8;
  localparam int U_BOOL1 = 8 + NINC;                  // the boolean units after the first come after the increment units
  localparam int NU = 8 + NINC + NBOOL - 1;           // units that have an entry
  function automatic logic is_inc(input int u); is_inc = (u >= U_INC0) && (u < U_INC0 + NINC); endfunction
  function automatic logic is_bool(input int u); is_bool = (u == U_BOOL) || (u >= U_BOOL1); endfunction
  localparam int NB = 2 * (NU + 1);                   // result buses: two for each unit and two for the memory
  localparam int Q = 4;                               // memory queue
  localparam logic [17:0] DEV_BASE = 18'o120000;

  // unit kinds of an instruction
  localparam logic [3:0] UK_BR = 4'd0, UK_BOOL = 4'd1, UK_SHIFT = 4'd2, UK_LADD = 4'd3, UK_FADD = 4'd4, UK_MUL = 4'd5,
                         UK_DIV = 4'd6, UK_INC = 4'd7, UK_NONE = 4'd8, UK_NORM = 4'd9;

  // registers by number: X0-7 are 0-7, A0-7 are 8-15, B0-7 are 16-23
  function automatic logic [4:0] rx_(input logic [2:0] n); rx_ = {2'b00, n}; endfunction
  function automatic logic [4:0] ra_(input logic [2:0] n); ra_ = {2'b01, n}; endfunction
  function automatic logic [4:0] rb_(input logic [2:0] n); rb_ = {2'b10, n}; endfunction

  function automatic int lat_of(input int u);
    if (u == U_BOOL || u >= U_BOOL1) lat_of = LAT_BOOL;
    else if (u == U_SHIFT) lat_of = LAT_SHIFT;
    else if (u == U_LADD) lat_of = 2;
    else if (u == U_FADD) lat_of = 5;
    else if (u == U_MUL) lat_of = 7;
    else if (u == U_DIV) lat_of = 3;
    else if (u == U_NORM) lat_of = 3;
    else if (u >= U_INC0) lat_of = LAT_INC;
    else lat_of = 1;
  endfunction

  // ------------------------------------------------------------------ memory
  logic [59:0] mem[0:(1<<MEM_AW)-1];
  logic [MEM_AW-1:0] iaddr, daddr;
  logic ld_v_next;
  logic [4:0] ld_t_next;
  logic [59:0] irdata, drdata, dwdata;
  logic dwe;

  generate
    if (EXT_MEM) begin : g_ext
      assign ext_iaddr = iaddr;
      assign ext_addr  = daddr;
      assign ext_we    = dwe;
      assign ext_wdata = dwdata;
      assign irdata    = ext_irdata;
      assign drdata    = ext_rdata;
    end else begin : g_int
      assign ext_iaddr = '0; assign ext_addr = '0; assign ext_we = 1'b0; assign ext_wdata = 60'd0;
      initial begin
        if (MEM_INIT != "") $readmemh(MEM_INIT, mem);
      end
      always_ff @(posedge clk) begin
        if (reset) begin
          if (load_we) mem[load_addr] <= load_data;
        end else if (dwe) mem[daddr] <= dwdata;
        irdata <= mem[iaddr];
        drdata <= mem[daddr];
      end
    end
  endgenerate

  // ------------------------------------------------------------------ architectural state
  logic [59:0] xr[0:7];
  logic [17:0] ar[0:7];
  logic [17:0] br[0:7];
  logic [59:0] xs[0:7];                                // SPEC: the registers as they were when the branch went into the branch unit, plus
  logic [17:0] as[0:7];                                // what the instructions before it wrote since; the live copy above also takes the
  logic [17:0] bs[0:7];                                // results of the instructions after it, and is restored from here on a wrong guess
  logic [59:0] io_file;
  logic [2:0]  boot;                                   // 0-3: reading the boot block, 4: running

  // reservations: who will write each register
  logic [23:0] rsv_v;
  logic [4:0]  rsv_t[0:23];                            // {tag, port}
  logic [1:0]  tag_pend[0:15];                         // results outstanding for each tag, one bit for each port
  logic [23:0] rsv_spec;                               // the reservation was made after the branch that waits in the branch unit
  logic [15:0] tag_spec;                               // the same for the tags
  logic [23:0] sh_v;                                   // a speculative instruction took the register over from an instruction before the
  logic [4:0]  sh_t[0:23];                             // branch that has not written it yet: its tag.  Its result goes into the copy only,
                                                       // and comes back as the reservation if the guess was wrong

  // ------------------------------------------------------------------ the instruction decoder
  typedef struct packed {
    logic [3:0] uk;
    logic       d0v;  logic [4:0] d0r;                 // results: the first (also the A of a load), the second (B of a normalise)
    logic       d1v;  logic [4:0] d1r;
    logic       s0v;  logic [4:0] s0r;                 // operands
    logic       s1v;  logic [4:0] s1r;
    logic       mld;                                   // SA1-5: loads X(i), reserved by the memory
    logic       mst;                                   // SA6-7: stores X(i) (source sdr)
    logic [4:0] sdr;
    logic       rj;                                    // RJ: stores the return jump, jumps to K+1
    logic       jimm;                                  // JP with no register: jumps at issue
    logic       special;                               // PS: stops the machine
  } dec_t;

  function automatic dec_t decode(input logic [5:0] f, input logic [2:0] i, input logic [2:0] j, input logic [2:0] k);
    dec_t d;
    logic [2:0] g;
    d = '0;
    d.uk = UK_NONE;
    g = f[2:0];
    case (f)
      6'o00: d.special = 1'b1;
      6'o01: begin d.rj = 1'b1; end
      6'o02: begin
        if (i == 3'd0) d.jimm = 1'b1;
        else begin d.uk = UK_BR; d.s0v = 1'b1; d.s0r = rb_(i); end
      end
      6'o03: begin d.uk = UK_BR; d.s0v = 1'b1; d.s0r = rx_(j); end
      6'o04, 6'o05, 6'o06, 6'o07: begin
        d.uk = UK_BR;
        if (i != 0) begin d.s0v = 1'b1; d.s0r = rb_(i); end
        if (j != 0) begin d.s1v = 1'b1; d.s1r = rb_(j); end
      end
      6'o10: begin d.uk = UK_BOOL; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); end
      6'o11, 6'o12, 6'o13, 6'o15, 6'o16, 6'o17: begin
        d.uk = UK_BOOL; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); d.s1v = 1; d.s1r = rx_(k);
      end
      6'o14: begin d.uk = UK_BOOL; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(k); end
      6'o43: begin d.uk = UK_BOOL; d.d0v = 1; d.d0r = rx_(i); end
      6'o20, 6'o21: begin d.uk = UK_SHIFT; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(i); end
      6'o22, 6'o23: begin
        d.uk = UK_SHIFT; d.d0v = 1; d.d0r = rx_(i);
        if (j != 0) begin d.s0v = 1; d.s0r = rb_(j); end
        d.s1v = 1; d.s1r = rx_(k);
      end
      6'o24, 6'o25, 6'o26: begin
        d.uk = UK_NORM; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(k);
        if (j != 0) begin d.d1v = 1; d.d1r = rb_(j); end
      end
      6'o27: begin
        d.uk = UK_NORM; d.d0v = 1; d.d0r = rx_(i);
        if (j != 0) begin d.s0v = 1; d.s0r = rb_(j); end
        d.s1v = 1; d.s1r = rx_(k);
      end
      6'o47: begin d.uk = UK_NORM; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(k); end
      6'o30, 6'o31, 6'o32, 6'o33, 6'o34, 6'o35: begin
        d.uk = UK_FADD; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); d.s1v = 1; d.s1r = rx_(k);
      end
      6'o36, 6'o37: begin
        d.uk = UK_LADD; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); d.s1v = 1; d.s1r = rx_(k);
      end
      6'o40, 6'o41, 6'o42: begin
        d.uk = UK_MUL; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); d.s1v = 1; d.s1r = rx_(k);
      end
      6'o44, 6'o45: begin
        d.uk = UK_DIV; d.d0v = 1; d.d0r = rx_(i); d.s0v = 1; d.s0r = rx_(j); d.s1v = 1; d.s1r = rx_(k);
      end
      6'o46: ;
      default: begin
        // 50-57 SA (A(i)), 60-67 SB (B(i)), 70-77 SX (X(i)): one sum of A/B/X operands and a constant
        d.uk = UK_INC;
        if (f[5:3] == 3'd5) begin
          d.d0v = 1; d.d0r = ra_(i);
          if (i >= 3'd1 && i <= 3'd5) d.mld = 1'b1;
          else if (i >= 3'd6) begin d.mst = 1'b1; d.sdr = rx_(i); end
        end else if (f[5:3] == 3'd6) begin
          if (i != 0) begin d.d0v = 1; d.d0r = rb_(i); end
        end else begin
          d.d0v = 1; d.d0r = rx_(i);
        end
        case (g)
          3'd0: begin d.s0v = 1; d.s0r = ra_(j); end
          3'd1: begin if (j != 0) begin d.s0v = 1; d.s0r = rb_(j); end end
          3'd2: begin d.s0v = 1; d.s0r = rx_(j); end
          3'd3: begin d.s0v = 1; d.s0r = rx_(j); if (k != 0) begin d.s1v = 1; d.s1r = rb_(k); end end
          3'd4, 3'd5: begin d.s0v = 1; d.s0r = ra_(j); if (k != 0) begin d.s1v = 1; d.s1r = rb_(k); end end
          default: begin
            if (j != 0) begin d.s0v = 1; d.s0r = rb_(j); end
            if (k != 0) begin d.s1v = 1; d.s1r = rb_(k); end
          end
        endcase
      end
    endcase
    decode = d;
  endfunction

  function automatic logic is_long_f(input logic [5:0] f);
    is_long_f = (f >= 6'o01 && f <= 6'o07) || f == 6'o50 || f == 6'o51 || f == 6'o52 ||
                f == 6'o60 || f == 6'o61 || f == 6'o62 || f == 6'o70 || f == 6'o71 || f == 6'o72;
  endfunction

  function automatic logic is_dev(input logic [17:0] ad);
    is_dev = (ad[17:12] == 6'o12) || (ad[17:12] == 6'o13 && ad[11:4] == 8'd0);       // 120000B .. 130017B, without a comparator
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

  // ------------------------------------------------------------------ front end: instruction stack, fetch, decode register
  logic [59:0]       sk_d[0:NSK-1];
  logic [MEM_AW-1:0] sk_a[0:NSK-1];
  logic [NSK-1:0]    sk_v;
  logic [$clog2(NSK)-1:0] sk_wp;
  logic [17:0]       dp_w;                              // the word, and the parcel in it, that decode takes next
  logic [1:0]        dp_s;
  logic [4:0]        dp_nskip;                          // no-operations passed since the last instruction
  logic              f_v, f_drop;                       // a word was asked for last cycle
  logic [MEM_AW-1:0] f_a;

  // the decode register: two slots, slot 0 the older (DUAL = 0: only slot 0 is ever filled)
  typedef struct packed {
    logic [17:0]       w;                               // the word and the parcel the instruction came from
    logic [1:0]        s;
    logic [5:0]        f;
    logic [2:0]        i, j, k;
    logic [17:0]       K;
    logic [4:0]        ns;                              // no-operations passed since the instruction before (counted with this one)
    logic              pred;                            // decode followed the branch to its target (a guess)
    logic [17:0]       fw;                              // where the code goes on if it does not branch: word and parcel
    logic [1:0]        fs;
    logic [BHT_AW-1:0] idx;                             // its place in the history table
    dec_t              D;                               // its decoding
    logic              bad;                             // a 30 bit instruction in the last parcel
  } drs_t;
  drs_t              dr[0:1];
  logic [1:0]        dr_v;
  logic [1:0]        bht[0:(1<<BHT_AW)-1];
  initial for (int q = 0; q < (1<<BHT_AW); q++) bht[q] = 2'b10;

  // data written into memory this cycle (keeps the instruction stack right)
  logic              st_v;
  logic [MEM_AW-1:0] st_a;
  logic [59:0]       st_d;

  logic redirect_v;
  logic [17:0] redirect_t;
  logic [1:0]  redirect_s;
  logic [1:0] issue_fire;                              // slot 0 and slot 1 of the decode register issue this cycle

  logic [MEM_AW-1:0] dpa;
  assign dpa = dp_w[MEM_AW-1:0];
  assign iaddr = (boot == 3'd4 && want_v) ? want_a : dpa;
  logic [$clog2(NSK)-1:0] fill_i;                   // the entry that the word on its way replaces: the next one, but not the word being decoded
  always_comb begin
    fill_i = sk_wp;
    if (sk_v[sk_wp] && sk_a[sk_wp] == dpa) fill_i = sk_wp + 1'b1;
  end
  // the word fetched comes from memory.  If a store to it is being done this cycle, or still waits in the memory queue (the return
  // jump an RJ writes into the word it calls: the call's JP back can come before the store is done, now that it is not the only thing
  // going on), the word that came is void and is asked for again: muxing the store's data in here would put the memory queue in
  // front of the whole decode, which is the longest path of the core.  Only the queue entries are looked at, registers all: a store
  // being done this cycle is still an entry, with the entry's address (s_a), so whether it is done this cycle (which depends on its
  // data arriving on a bus) does not enter the decode either.
  logic [59:0] ret_data;
  logic        f_void;
  always_comb begin
    f_void = 1'b0;
    for (int q = 0; q < Q; q++) if (mq_v[q] && mq_st[q] && mq_av[q] && mq_a[q][MEM_AW-1:0] == f_a) f_void = 1'b1;
    ret_data = irdata;
  end

  logic [NSK-1:0] hit_n;
  logic [59:0] dw, dw1;
  logic dec_hit, dec_hit1;
  logic [4:0] present;
  logic [MEM_AW-1:0] want_a;
  logic want_v;
  logic [MEM_AW-1:0] pf_a[0:4];
  logic pf_c[0:4];
  logic [MEM_AW-1:0] pf_tgt;
  logic pf_tv;
  always_comb begin
    dw = 60'd0;
    for (int n = 0; n < NSK; n++) begin
      hit_n[n] = sk_v[n] && (sk_a[n] == dpa);
      if (hit_n[n]) dw = dw | sk_d[n];
    end
    if (f_v && !f_drop && !f_void && f_a == dpa) begin
      dw = ret_data;
      dec_hit = 1'b1;
    end else dec_hit = |hit_n;
    // and the word after it, for the second instruction of a pair
    dw1 = 60'd0; dec_hit1 = 1'b0;
    for (int n = 0; n < NSK; n++) if (sk_v[n] && (sk_a[n] == dpa + MEM_AW'(1))) begin dw1 = dw1 | sk_d[n]; dec_hit1 = 1'b1; end
    if (f_v && !f_drop && !f_void && f_a == dpa + MEM_AW'(1)) begin dw1 = ret_data; dec_hit1 = 1'b1; end
    // prefetch candidates in order: the word being decoded, the target of a branch waiting in the decode register, the next three words
    pf_a[0] = dpa; pf_a[1] = pf_tgt; pf_a[2] = dpa + MEM_AW'(1); pf_a[3] = dpa + MEM_AW'(2); pf_a[4] = dpa + MEM_AW'(3);
    pf_c[0] = 1'b1; pf_c[1] = pf_tv; pf_c[2] = 1'b1; pf_c[3] = 1'b1; pf_c[4] = 1'b1;
    for (int q = 0; q < 5; q++) begin
      logic inst;
      inst = 1'b0;
      for (int n = 0; n < NSK; n++) if (sk_v[n] && sk_a[n] == pf_a[q]) inst = 1'b1;
      if (f_v && !f_drop && !f_void && f_a == pf_a[q]) inst = 1'b1;
      present[q] = inst || !pf_c[q];
    end
    want_v = 1'b0; want_a = dpa;
    for (int q = 4; q >= 0; q--) if (!present[q]) begin want_v = 1'b1; want_a = pf_a[q]; end
  end

  // decode: the window is the word being decoded and the one after it (8 parcels).  The first instruction (A) is looked for from
  // dp_s in the first word, the second (B, DUAL) after A in either word, if the second word is there.  No-operations passed are
  // skipped and counted
  logic [14:0] pp[0:7];
  logic [3:0]  posA, endA, posB, endB;                 // parcel positions in the window: 0..7, 8 = past it
  logic [4:0]  skipA, skipB;
  logic        foundA, foundB, plA, plB, badA;
  logic [14:0] pcA0, pcA1, pcB0, pcB1;
  logic [5:0]  pfA, pfB;
  always_comb begin
    pp[0] = dw[59:45]; pp[1] = dw[44:30]; pp[2] = dw[29:15]; pp[3] = dw[14:0];
    pp[4] = dw1[59:45]; pp[5] = dw1[44:30]; pp[6] = dw1[29:15]; pp[7] = dw1[14:0];
    foundA = 1'b0; posA = 4'd4; skipA = 5'd0;
    for (int q = 0; q < 4; q++) if (!foundA && q >= dp_s) begin
      if (pp[q][14:9] == 6'o46) skipA = skipA + 5'd1; else begin foundA = 1'b1; posA = 4'(q); end
    end
    pcA0 = foundA ? pp[posA[1:0]] : 15'd0; pfA = pcA0[14:9];
    plA = foundA && is_long_f(pfA);
    badA = plA && (posA == 4'd3);
    pcA1 = (posA < 4'd3) ? pp[posA[1:0] + 2'd1] : 15'd0;
    endA = foundA ? posA + (plA ? 4'd2 : 4'd1) : 4'd4;
    foundB = 1'b0; posB = 4'd8; skipB = 5'd0;
    if (DUAL && foundA && !badA)
      for (int q = 0; q < 8; q++) if (!foundB && 4'(q) >= endA && (q < 4 || dec_hit1)) begin
        if (pp[q][14:9] == 6'o46) skipB = skipB + 5'd1; else begin foundB = 1'b1; posB = 4'(q); end
      end
    pcB0 = foundB ? pp[posB[2:0]] : 15'd0; pfB = pcB0[14:9];
    plB = foundB && is_long_f(pfB);
    if (plB && posB[1:0] == 2'd3) foundB = 1'b0;         // a 30 bit instruction in the last parcel: it is A next time, and stops there
    pcB1 = (posB[1:0] < 2'd3 && posB < 4'd7) ? pp[posB[2:0] + 3'd1] : 15'd0;
    endB = foundB ? posB + (plB ? 4'd2 : 4'd1) : 4'd8;
  end

  // where decode goes on from the end of A (ndA) or of B (ndB): the trailing no-operations of that word are passed over at once
  // (and counted with the next instruction)
  logic        restA, restB;
  logic [4:0]  trailA, trailB;
  logic [17:0] dp_w1, dp_wn[0:3];                       // dp_w + 1, and dp_w + 0..3: from the register, so that a late sum only selects
  always_comb begin
    dp_w1 = dp_w + 18'd1;
    dp_wn[0] = dp_w; dp_wn[1] = dp_w1; dp_wn[2] = dp_w + 18'd2; dp_wn[3] = dp_w + 18'd3;
  end
  logic [17:0] ndA_w, ndB_w;
  logic [1:0]  ndA_s, ndB_s;
  always_comb begin
    restA = 1'b1; restB = 1'b1;
    for (int q = 0; q < 8; q++) begin
      if (4'(q) >= endA && q[2] == endA[2] && pp[q][14:9] != 6'o46) restA = 1'b0;
      if (4'(q) >= endB && q[2] == endB[2] && pp[q][14:9] != 6'o46) restB = 1'b0;
    end
    trailA = (endA[1:0] != 2'd0 && restA) ? 5'(3'd4 - endA[1:0]) : 5'd0;
    ndA_w = dp_wn[2'(endA[3:2]) + 2'((endA[1:0] != 2'd0) && restA)];
    ndA_s = (endA[1:0] != 2'd0 && restA) ? 2'd0 : endA[1:0];
    trailB = (endB[1:0] != 2'd0 && restB) ? 5'(3'd4 - endB[1:0]) : 5'd0;
    ndB_w = dp_wn[2'(endB[3:2]) + 2'((endB[1:0] != 2'd0) && restB)];
    ndB_s = (endB[1:0] != 2'd0 && restB) ? 2'd0 : endB[1:0];
  end

  // the history table is read for the four parcels of the word being decoded and of the one after it, from the registered dp_w, so
  // that the late parcel positions only select among the eight entries (the table read is otherwise on the longest path of the core)
  logic bht_rd[0:1][0:3];
  always_comb begin
    for (int p = 0; p < 4; p++) begin
      bht_rd[0][p] = bht[{dp_w[BHT_AW-3:0], 2'(p)}][1];
      bht_rd[1][p] = bht[{dp_w1[BHT_AW-3:0], 2'(p)}][1];
    end
  end

  // ---- the guess: unconditional jumps and calls with a known place are followed at once; a conditional branch as the table says.
  // B goes with A only when A does not change the flow at decode
  logic        d_condA, d_staticA, d_predA, d_takepA, d_condB, d_staticB, d_predB, d_takepB, canB;
  logic [17:0] KA, KB, d_tgtA, d_tgtB, wB;
  logic [BHT_AW-1:0] d_idxA, d_idxB;
  always_comb begin
    KA = {pcA0[2:0], pcA1}; KB = {pcB0[2:0], pcB1};
    d_condA = foundA && !badA && (pfA >= 6'o03 && pfA <= 6'o07);
    d_staticA = foundA && !badA && ((pfA == 6'o01) || (pfA == 6'o02 && pcA0[8:6] == 3'd0));
    d_idxA = {dp_w[BHT_AW-3:0], posA[1:0]};
    d_predA = bht_rd[0][posA[1:0]];                       // read for every parcel from the registered dp_w; the late position selects
    d_takepA = d_staticA || (d_condA && d_predA);
    d_tgtA = (pfA == 6'o01) ? KA + 18'd1 : KA;
    wB = posB[2] ? dp_w1 : dp_w;
    d_condB = foundB && (pfB >= 6'o03 && pfB <= 6'o07);
    d_staticB = foundB && ((pfB == 6'o01) || (pfB == 6'o02 && pcB0[8:6] == 3'd0));
    d_idxB = {wB[BHT_AW-3:0], posB[1:0]};
    d_predB = bht_rd[posB[2]][posB[1:0]];
    d_takepB = d_staticB || (d_condB && d_predB);
    d_tgtB = (pfB == 6'o01) ? KB + 18'd1 : KB;
    canB = foundB && !d_takepA;
  end

  // what decode consumes this cycle (0, 1 or 2 instructions) and the slot contents it makes of them
  logic [1:0] keep, ncons, avail, free_;
  drs_t candA, candB;
  always_comb begin
    keep[0] = dr_v[0] && !issue_fire[0]; keep[1] = dr_v[1] && !issue_fire[1];
    free_ = 2'd2 - 2'(keep[0]) - 2'(keep[1]);
    avail = (boot == 3'd4 && dec_hit && foundA) ? (canB ? 2'd2 : 2'd1) : 2'd0;
    ncons = (avail < free_) ? avail : free_;
    candA = '0;
    candA.w = dp_w; candA.s = posA[1:0]; candA.f = pfA; candA.i = pcA0[8:6]; candA.j = pcA0[5:3]; candA.k = pcA0[2:0];
    candA.K = KA; candA.ns = dp_nskip + skipA; candA.bad = badA;
    candA.D = badA ? Dbad : decode(pfA, pcA0[8:6], pcA0[5:3], pcA0[2:0]);
    candA.pred = d_condA && d_predA; candA.fw = ndA_w; candA.fs = ndA_s; candA.idx = d_idxA;
    candB = '0;
    candB.w = wB; candB.s = posB[1:0]; candB.f = pfB; candB.i = pcB0[8:6]; candB.j = pcB0[5:3]; candB.k = pcB0[2:0];
    candB.K = KB; candB.ns = skipB; candB.bad = 1'b0;
    candB.D = decode(pfB, pcB0[8:6], pcB0[5:3], pcB0[2:0]);
    candB.pred = d_condB && d_predB; candB.fw = ndB_w; candB.fs = ndB_s; candB.idx = d_idxB;
  end

  // ------------------------------------------------------------------ issue
  // the place a branch in the decode register goes to, when it is known
  always_comb begin
    pf_tv = 1'b0; pf_tgt = '0;
    for (int s = 1; s >= 0; s--)                                                   // slot 0 first
      if (dr_v[s] && !dr[s].bad && dr[s].f >= 6'o03 && dr[s].f <= 6'o07) begin
        pf_tv = 1'b1; pf_tgt = dr[s].pred ? MEM_AW'(dr[s].fw) : MEM_AW'(dr[s].K);   // the other way
      end
    if (!pf_tv && e_v[U_BR] && e_f[U_BR] >= 6'o03 && e_f[U_BR] <= 6'o07) begin     // or of the branch waiting in the branch unit
      pf_tv = 1'b1; pf_tgt = bu_pred ? MEM_AW'(bu_fw) : MEM_AW'(e_K[U_BR]);
    end
  end
  // the instruction is decoded when it goes into the decode register, so issue starts from registers
  dec_t D[0:1], Dbad;
  always_comb begin
    Dbad = '0; Dbad.uk = UK_NONE; Dbad.special = 1'b1;
    D[0] = dr[0].D; D[1] = dr[1].D;
  end

  // units: entries
  logic [NU-1:0]  e_v;
  logic [NU-1:0]  e_spec;                               // issued after the branch in the branch unit
  logic [5:0]     e_f[0:NU-1];
  logic [8:0]     e_ijk[0:NU-1];
  logic [17:0]    e_K[0:NU-1];
  logic [3:0]     e_tag[0:NU-1];
  logic           e_d0v[0:NU-1];
  logic           e_d1v[0:NU-1];
  logic [59:0]    e_s0[0:NU-1];
  logic [59:0]    e_s1[0:NU-1];
  logic           e_w0[0:NU-1];
  logic           e_w1[0:NU-1];
  logic [4:0]     e_t0[0:NU-1];
  logic [4:0]     e_t1[0:NU-1];
  logic           e_mf[0:NU-1];
  logic [1:0]     e_mq[0:NU-1];
  logic [17:0]    e_wd[0:NU-1];                         // word address of the instruction (branch unit: not used)
  logic [NU-1:0]  launch;
  logic [NU-1:0]  accept;

  // result buses
  logic        rb_v[0:NB-1];
  logic [4:0]  rb_t[0:NB-1];
  logic [59:0] rb_d[0:NB-1];

  function automatic logic [60:0] busf(input logic [4:0] t);
    logic [60:0] r;
    r = 61'd0;
    for (int b = 0; b < NB; b++) if (rb_v[b] && rb_t[b] == t) begin r[60] = 1'b1; r[59:0] = rb_d[b]; end
    busf = r;
  endfunction

  function automatic logic [59:0] regval(input logic [4:0] r);
    if (r[4:3] == 2'b00) regval = xr[r[2:0]];
    else if (r[4:3] == 2'b01) regval = {42'd0, ar[r[2:0]]};
    else regval = {42'd0, br[r[2:0]]};
  endfunction

  // free tags: the two lowest; slot 1 takes the first if slot 0 needs none
  logic [1:0] tag_okv, tg_ok, need_tag;
  logic [3:0] new_tag[0:1], tg[0:1];
  always_comb begin
    tag_okv = 2'b00; new_tag[0] = 4'd0; new_tag[1] = 4'd0;
    for (int t = 15; t >= 0; t--) if (tag_pend[t] == 2'b00) begin tag_okv[0] = 1'b1; new_tag[0] = t[3:0]; end
    for (int t = 15; t >= 0; t--) if (tag_pend[t] == 2'b00 && t[3:0] != new_tag[0]) begin tag_okv[1] = 1'b1; new_tag[1] = t[3:0]; end
    tg[0] = new_tag[0]; tg_ok[0] = tag_okv[0];
    tg[1] = need_tag[0] ? new_tag[1] : new_tag[0]; tg_ok[1] = need_tag[0] ? tag_okv[1] : tag_okv[0];
  end

  // the three operands an instruction may read at issue: s0, s1 and the data of a store.  Slot 1 takes what slot 0 writes as the tag
  // slot 0 is given
  logic [59:0] o_v[0:1][0:2];
  logic        o_w[0:1][0:2];
  logic [4:0]  o_t[0:1][0:2];
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      logic [4:0] rr[0:2];
      logic       use_[0:2];
      use_[0] = D[s].s0v; rr[0] = D[s].s0r;
      use_[1] = D[s].s1v; rr[1] = D[s].s1r;
      use_[2] = D[s].mst; rr[2] = D[s].sdr;
      for (int k = 0; k < 3; k++) begin
        logic [60:0] bf;
        o_v[s][k] = 60'd0; o_w[s][k] = 1'b0; o_t[s][k] = 5'd0;
        bf = 61'd0;
        if (use_[k]) begin
          if (s == 1 && D[0].d0v && D[0].d0r == rr[k]) begin o_w[s][k] = 1'b1; o_t[s][k] = {new_tag[0], 1'b0}; end
          else if (s == 1 && ((D[0].d1v && D[0].d1r == rr[k]) || (D[0].mld && rx_(dr[0].i) == rr[k]))) begin
            o_w[s][k] = 1'b1; o_t[s][k] = {new_tag[0], 1'b1};
          end else if (rsv_v[rr[k]]) begin
            bf = busf(rsv_t[rr[k]]);
            o_t[s][k] = rsv_t[rr[k]];
            if (bf[60]) o_v[s][k] = bf[59:0]; else o_w[s][k] = 1'b1;
          end else o_v[s][k] = regval(rr[k]);
        end
      end
    end
  end

  // memory queue
  logic [Q-1:0]  mq_v, mq_st, mq_av, mq_dv, mq_dw, mq_spec;
  logic [17:0]   mq_a[0:Q-1];
  logic [59:0]   mq_d[0:Q-1];
  logic [4:0]    mq_dt[0:Q-1];
  logic [4:0]    mq_rt[0:Q-1];
  logic [1:0]    mq_head, mq_tail;
  logic [2:0]    mq_n, mq_nspec;                       // entries, and how many of them are speculative
  logic          mq_pop;
  always_comb begin
    mq_nspec = 3'd0;
    for (int q = 0; q < Q; q++) if (mq_v[q] && mq_spec[q]) mq_nspec = mq_nspec + 3'd1;
  end

  logic drained;
  logic hold;                                          // issue is held
  logic br_pend, halt_req;
  // speculation: a branch waits in the branch unit (br_pend) and issue goes on; the cycle it is decided, squash_now (wrong) or the
  // registered sq_r / commit_r (the cycle after) undo or keep what was issued meanwhile.  Nothing issues during sq_r.
  logic        spec_issue, squash_now, sq_r, commit_r, ckpt_now;
  logic [31:0] spec_cnt;                                // instructions (with the no-operations they carry) issued since the branch
  logic [15:0] spec_ni;                                 // issued instructions since the branch (for the trace)
  logic        bu_pred;                                 // the guess for the branch in the branch unit, and where it goes on
  logic [17:0] bu_fw;
  logic [1:0]  bu_fs;
  logic [BHT_AW-1:0] bu_idx;
  logic [6:0] halt_cnt;

  logic [1:0] unit_ok, dest_ok, need_mq, mq_okv, sp_ok, spec_is;
  logic [4:0] sel_u[0:1];
  always_comb begin
    spec_is[0] = SPEC && br_pend;
    spec_is[1] = SPEC && (br_pend || (D[0].uk == UK_BR && !br_early[0]));      // after a branch that slot 0 sends to the branch unit
    for (int s = 0; s < 2; s++) begin
      unit_ok[s] = 1'b0; sel_u[s] = 5'd0;
      case (D[s].uk)
        UK_BR: begin unit_ok[s] = br_early[s] || (SPEC ? !e_v[U_BR] : accept[U_BR]); sel_u[s] = U_BR; end   // SPEC: not in the cycle the one before is decided
        UK_BOOL: begin                                  // the first boolean unit, or one of the others; slot 1 not the one slot 0 takes
          for (int n = NU - 1; n >= U_BOOL1; n--)
            if (accept[n] && !(s == 1 && D[0].uk == UK_BOOL && sel_u[0] == 5'(n))) begin unit_ok[s] = 1'b1; sel_u[s] = 5'(n); end
          if (accept[U_BOOL] && !(s == 1 && D[0].uk == UK_BOOL && sel_u[0] == 5'(U_BOOL))) begin unit_ok[s] = 1'b1; sel_u[s] = U_BOOL; end
        end
        UK_SHIFT: begin unit_ok[s] = accept[U_SHIFT]; sel_u[s] = U_SHIFT; end
        UK_LADD: begin unit_ok[s] = accept[U_LADD]; sel_u[s] = U_LADD; end
        UK_FADD: begin unit_ok[s] = accept[U_FADD]; sel_u[s] = U_FADD; end
        UK_MUL: begin unit_ok[s] = accept[U_MUL]; sel_u[s] = U_MUL; end
        UK_DIV: begin unit_ok[s] = accept[U_DIV]; sel_u[s] = U_DIV; end
        UK_NORM: begin unit_ok[s] = accept[U_NORM]; sel_u[s] = U_NORM; end
        UK_INC: begin                                   // slot 1 takes another increment unit than slot 0
          for (int n = NINC - 1; n >= 0; n--)
            if (accept[U_INC0 + n] && !(s == 1 && D[0].uk == UK_INC && sel_u[0] == 5'(U_INC0 + n))) begin unit_ok[s] = 1'b1; sel_u[s] = 5'(U_INC0 + n); end
        end
        default: unit_ok[s] = 1'b1;
      endcase
      // RELAX_WAW: the newer instruction takes the destination over (a speculative one from an instruction before the branch too: sh_t
      // remembers that one)
      dest_ok[s] = RELAX_WAW || ((!D[s].d0v || !rsv_v[D[s].d0r]) && (!D[s].d1v || !rsv_v[D[s].d1r]) && (!D[s].mld || !rsv_v[rx_(dr[s].i)]));
      need_tag[s] = D[s].d0v || D[s].d1v || D[s].mld;
      need_mq[s] = D[s].mld || D[s].mst || D[s].rj;
    end
    // one entry a unit: slot 1 does not take the unit slot 0 takes (the increment units are told apart above; two branches decided
    // at issue need no unit)
    if (D[1].uk != UK_NONE && D[1].uk != UK_INC && D[1].uk != UK_BOOL && D[0].uk == D[1].uk &&
        !(D[0].uk == UK_BR && br_early[0]) && !(D[1].uk == UK_BR && br_early[1]))
      unit_ok[1] = 1'b0;
    mq_okv[0] = !need_mq[0] || (mq_n < 3'd4);
    mq_okv[1] = !need_mq[1] || ((mq_n + 3'(need_mq[0])) < 3'd4);
    sp_ok[0] = !D[0].special || drained;
    sp_ok[1] = !D[1].special;
  end

  // early resolution: a conditional branch (or JP B) whose operands are not reserved (nor, in slot 1, written by slot 0) is decided
  // at issue; otherwise the branch unit waits for them
  logic [1:0]  br_early, br_e_tk;
  logic [59:0] ebr0[0:1], ebr1[0:1];                    // the operands of the branch, read from the registers
  logic [17:0] br_e_tgt[0:1];
  logic [23:0] wr0;                                     // the registers slot 0 writes
  always_comb begin
    wr0 = 24'd0;
    if (D[0].d0v) wr0[D[0].d0r] = 1'b1;
    if (D[0].d1v) wr0[D[0].d1r] = 1'b1;
    if (D[0].mld) wr0[rx_(dr[0].i)] = 1'b1;
    for (int s = 0; s < 2; s++) begin
      logic signed [18:0] va, vb;
      logic dep0, dep1;
      dep0 = D[s].s0v && (rsv_v[D[s].s0r] || (s == 1 && wr0[D[s].s0r]));
      dep1 = D[s].s1v && (rsv_v[D[s].s1r] || (s == 1 && wr0[D[s].s1r]));
      br_early[s] = (D[s].uk == UK_BR) && !dep0 && !dep1;
      ebr0[s] = D[s].s0v ? regval(D[s].s0r) : 60'd0; ebr1[s] = D[s].s1v ? regval(D[s].s1r) : 60'd0;
      va = sb18(ebr0[s][17:0]); vb = sb18(ebr1[s][17:0]);
      br_e_tk[s] = 1'b0; br_e_tgt[s] = dr[s].K;
      case (dr[s].f)
        6'o02: begin br_e_tk[s] = 1'b1; br_e_tgt[s] = dr[s].K + ebr0[s][17:0]; end
        6'o03: br_e_tk[s] = cond(dr[s].i, ebr0[s]);
        6'o04: br_e_tk[s] = (va == vb);
        6'o05: br_e_tk[s] = (va != vb);
        6'o06: br_e_tk[s] = (va >= vb);
        6'o07: br_e_tk[s] = (va < vb);
        default: ;
      endcase
    end
  end

  // jumps taken at issue: a branch decided at issue against the guess decode made (slot 0 first; slot 1 does not issue then)
  logic jump_now0, jump_now1, jump_now;
  logic [17:0] jump_t;
  logic [1:0]  jump_s;
  always_comb begin
    jump_now0 = issue_fire[0] && br_early[0] && (br_e_tk[0] != dr[0].pred);
    jump_now1 = issue_fire[1] && br_early[1] && (br_e_tk[1] != dr[1].pred);
    jump_now = jump_now0 || jump_now1;
    if (jump_now0) begin jump_t = br_e_tk[0] ? br_e_tgt[0] : dr[0].fw; jump_s = br_e_tk[0] ? 2'd0 : dr[0].fs; end
    else begin jump_t = br_e_tk[1] ? br_e_tgt[1] : dr[1].fw; jump_s = br_e_tk[1] ? 2'd0 : dr[1].fs; end
  end

  assign ckpt_now = SPEC && ((issue_fire[0] && D[0].uk == UK_BR && !br_early[0]) || (issue_fire[1] && D[1].uk == UK_BR && !br_early[1]));
  assign hold = (SPEC ? sq_r : br_pend) || halt_req || halted;
  assign issue_fire[0] = dr_v[0] && boot == 3'd4 && !hold && unit_ok[0] && dest_ok[0] && (!need_tag[0] || tg_ok[0]) && mq_okv[0] && sp_ok[0];
  assign issue_fire[1] = DUAL && issue_fire[0] && dr_v[1] && unit_ok[1] && dest_ok[1] && (!need_tag[1] || tg_ok[1]) && mq_okv[1] && sp_ok[1] &&
                         !jump_now0 && !D[0].special;

  // what is issued this cycle: instructions (with their no-operations), of them speculative, memory queue entries
  logic [7:0] iss_icnt, iss_spec_cnt;
  logic [1:0] iss_spec_ni, iss_nmq;
  always_comb begin
    iss_icnt = 8'd0; iss_spec_cnt = 8'd0; iss_spec_ni = 2'd0; iss_nmq = 2'd0;
    for (int s = 0; s < 2; s++) if (issue_fire[s]) begin
      iss_icnt = iss_icnt + 8'd1 + 8'(dr[s].ns);
      if (spec_is[s]) begin iss_spec_cnt = iss_spec_cnt + 8'd1 + 8'(dr[s].ns); iss_spec_ni = iss_spec_ni + 2'd1; end
      if (need_mq[s]) iss_nmq = iss_nmq + 2'd1;
    end
  end

  // ------------------------------------------------------------------ units: execution
  // the operands the unit would use are in e_s0/e_s1; the results go to the delay line of the unit
  logic [59:0] c_d0[0:NU-1];
  logic [17:0] c_d1[0:NU-1];
  logic        c_p1[0:NU-1];
  logic        c_v[0:NU-1];

  // divide: restoring, one quotient bit a cycle
  fl_t         dv_x, dv_y;
  logic [47:0] dv_xc, dv_yc;
  logic        dv_neg, dv_round, dv_run;
  int          dv_e;
  logic [49:0] dv_r;
  logic [50:0] dv_q;
  logic [5:0]  dv_cnt;
  nrm_t        dv_n;
  logic        dv_special_v, dv_fin;
  logic [59:0] dv_special_d;
  always_comb begin
    dv_x = funpack(e_s0[U_DIV]); dv_y = funpack(e_s1[U_DIV]);
    dv_special_v = 1'b0; dv_special_d = 60'd0;
    if (dv_y.c == 0) begin dv_special_v = 1'b1; dv_special_d = {12'h3ff, 48'd0}; end
    else if (dv_x.c == 0) begin dv_special_v = 1'b1; dv_special_d = 60'd0; end
    dv_n = '0;
    dv_n.zero = 1'b0; dv_n.neg = dv_neg; dv_n.m = NW'(dv_q); dv_n.e = 16'(dv_e);
  end
  logic [49:0] dv_rr;
  logic        dv_qb;
  always_comb begin
    dv_rr = (dv_cnt == 6'd0) ? {2'b00, dv_xc} : {dv_r[48:0], 1'b0};
    dv_qb = (dv_rr >= {2'b00, dv_yc});
  end

  // increment: the sum of two operands and a constant
  logic [17:0] inc_s[0:NU-1];
  always_comb begin
    for (int u = 0; u < NU; u++) begin
      logic [17:0] k18, s0_18, s1_18;
      k18 = e_K[u]; s0_18 = e_s0[u][17:0]; s1_18 = e_s1[u][17:0];
      case (e_f[u][2:0])
        3'd0, 3'd1, 3'd2: inc_s[u] = add18(k18, s0_18);
        3'd3, 3'd4: inc_s[u] = add18(s1_18, s0_18);
        3'd5: inc_s[u] = add18(neg18(s1_18), s0_18);
        3'd6: inc_s[u] = add18(s1_18, s0_18);
        default: inc_s[u] = add18(neg18(s1_18), s0_18);
      endcase
    end
  end

  // the address of a load or store, worked out at issue when its operands are there: the memory queue then does not wait for the increment unit
  logic [17:0] ag_sum[0:1];
  logic [1:0]  ag_ok;
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      logic [17:0] k18, a0, a1;
      k18 = dr[s].K; a0 = ebr0[s][17:0]; a1 = ebr1[s][17:0];
      case (dr[s].f[2:0])
        3'd0, 3'd1, 3'd2: ag_sum[s] = add18(k18, a0);
        3'd3, 3'd4, 3'd6: ag_sum[s] = add18(a1, a0);
        default: ag_sum[s] = add18(neg18(a1), a0);
      endcase
      // from the registers only (a bypass would chain two adders), and in slot 1 not from what slot 0 writes
      ag_ok[s] = AGEN && (D[s].mld || D[s].mst) && !(D[s].s0v && (rsv_v[D[s].s0r] || (s == 1 && wr0[D[s].s0r]))) &&
                 !(D[s].s1v && (rsv_v[D[s].s1r] || (s == 1 && wr0[D[s].s1r])));
    end
  end

  // branch unit
  logic        br_go, br_taken;
  logic [60:0] bu_b0, bu_b1;                           // the result bus as the branch unit's operands wait for it
  logic [59:0] bu_x0, bu_x1;
  logic [17:0] br_tgt;
  logic signed [18:0] bva, bvb;
  always_comb begin
    bu_b0 = busf(e_t0[U_BR]); bu_b1 = busf(e_t1[U_BR]);
    bu_x0 = e_w0[U_BR] ? bu_b0[59:0] : e_s0[U_BR];
    bu_x1 = e_w1[U_BR] ? bu_b1[59:0] : e_s1[U_BR];
    bva = sb18(bu_x0[17:0]); bvb = sb18(bu_x1[17:0]);
    br_taken = 1'b0; br_tgt = e_K[U_BR];
    case (e_f[U_BR])
      6'o02: begin br_taken = 1'b1; br_tgt = e_K[U_BR] + bu_x0[17:0]; end
      6'o03: br_taken = cond(e_ijk[U_BR][8:6], bu_x0);
      6'o04: br_taken = (bva == bvb);
      6'o05: br_taken = (bva != bvb);
      6'o06: br_taken = (bva >= bvb);
      6'o07: br_taken = (bva < bvb);
      default: ;
    endcase
  end

  always_comb begin
    for (int u = 0; u < NU; u++) begin
      logic [2:0] fi_, fj_, fk_;
      logic [5:0] f_;
      logic [17:0] bj18;
      logic [5:0] shn_;
      logic shl_;
      fi_ = e_ijk[u][8:6]; fj_ = e_ijk[u][5:3]; fk_ = e_ijk[u][2:0]; f_ = e_f[u];
      c_d0[u] = 60'd0; c_d1[u] = 18'd0; c_p1[u] = 1'b0; c_v[u] = 1'b0;
      bj18 = e_s0[u][17:0];
      shn_ = shcount(bj18); shl_ = !bj18[17];
      if (is_bool(u)) begin
        case (f_)
          6'o10: c_d0[u] = e_s0[u];
          6'o11: c_d0[u] = e_s0[u] & e_s1[u];
          6'o12: c_d0[u] = e_s0[u] | e_s1[u];
          6'o13: c_d0[u] = e_s0[u] ^ e_s1[u];
          6'o14: c_d0[u] = ~e_s0[u];
          6'o15: c_d0[u] = ~e_s1[u] & e_s0[u];
          6'o16: c_d0[u] = ~e_s1[u] | e_s0[u];
          6'o17: c_d0[u] = ~(e_s1[u] ^ e_s0[u]);
          default: c_d0[u] = mask43({fj_, fk_});
        endcase
      end else if (u == U_SHIFT) begin
        case (f_)
          6'o20: c_d0[u] = rotl60(e_s0[u], {fj_, fk_});
          6'o21: c_d0[u] = sar60(e_s0[u], {fj_, fk_});
          6'o22: c_d0[u] = shl_ ? rotl60(e_s1[u], shn_) : sar60(e_s1[u], shn_);
          default: c_d0[u] = shl_ ? sar60(e_s1[u], shn_) : rotl60(e_s1[u], shn_);
        endcase
      end else if (u == U_NORM) begin
        c_p1[u] = (f_ <= 6'o26) && (fj_ != 0);           // NX, ZX and UX also give a B register
      end else if (is_inc(u)) begin
        if (f_[5:3] == 3'd7) c_d0[u] = sx18(inc_s[u]); else c_d0[u] = {42'd0, inc_s[u]};
      end
    end
  end

  // the branch unit decides against the guess: what was issued after the branch is undone
  assign squash_now = SPEC && launch[U_BR] && (br_taken != bu_pred);

  // entry launch: operands there; the divider and the branch unit have their own rules
  always_comb begin
    for (int u = 0; u < NU; u++) begin
      launch[u] = e_v[u] && !e_w0[u] && !e_w1[u];
      accept[u] = !e_v[u] || launch[u];
    end
    // the branch unit decides in the cycle its operands appear on the result bus
    launch[U_BR] = e_v[U_BR] && (!e_w0[U_BR] || bu_b0[60]) && (!e_w1[U_BR] || bu_b1[60]);
    accept[U_BR] = !e_v[U_BR] || launch[U_BR];
    // the divider keeps its entry while it works
    launch[U_DIV] = e_v[U_DIV] && !e_w0[U_DIV] && !e_w1[U_DIV] && (dv_run ? dv_fin : dv_special_v);
    accept[U_DIV] = !e_v[U_DIV];
  end

  always_comb dv_fin = dv_run && (dv_cnt == 6'd51);

  // ------------------------------------------------------------------ the data paths of the units that are cut into stages
  logic [59:0] s_ladd, s_fadd, s_fmul, s_dv, s_norm0;
  logic [17:0] s_norm1;
  sb_ladd  ladd  (.clk(clk), .a(e_s0[U_LADD]), .b(e_s1[U_LADD]), .sub(e_f[U_LADD][0]), .r(s_ladd));
  sb_fadd  fadd  (.clk(clk), .a(e_s0[U_FADD]), .b(e_s1[U_FADD]), .f(e_f[U_FADD]), .r(s_fadd));
  sb_fmul  fmul  (.clk(clk), .a(e_s0[U_MUL]), .b(e_s1[U_MUL]), .f(e_f[U_MUL]), .r(s_fmul));
  sb_dvout dvout (.clk(clk), .run(dv_run), .n(dv_n), .round(dv_round), .sp_d(dv_special_d), .r(s_dv));
  sb_norm  norm  (.clk(clk), .w0(e_s0[U_NORM]), .w1(e_s1[U_NORM]), .f(e_f[U_NORM]), .r0(s_norm0), .r1(s_norm1));

  // ------------------------------------------------------------------ delay lines
  logic        u_o_v[0:NU-1];
  logic [3:0]  u_o_t[0:NU-1];
  logic [59:0] u_o_d0[0:NU-1];
  logic [17:0] u_o_d1[0:NU-1];
  logic        u_o_p1[0:NU-1];
  logic        u_o_mf[0:NU-1];
  logic [1:0]  u_o_mq[0:NU-1];
  logic [NU-1:0] u_o_busy;

  generate
    for (genvar g = 0; g < NU; g++) begin : g_unit
      logic in_v;
      logic [59:0] p_d0;
      logic [17:0] p_d1;
      assign in_v = launch[g] && (e_d0v[g] || e_d1v[g]) && (g != U_BR) && !(sq_r && e_spec[g]);
      sb_pipe #(.LAT(lat_of(g))) pipe (
        .clk(clk), .reset(reset), .kill(sq_r), .keep(commit_r),
        .in_v(in_v), .in_spec(e_spec[g]), .in_t(e_tag[g]), .in_d0(c_d0[g]), .in_d1(c_d1[g]), .in_p1(c_p1[g]), .in_mf(e_mf[g]), .in_mq(e_mq[g]),
        .out_v(u_o_v[g]), .out_t(u_o_t[g]), .out_d0(p_d0), .out_d1(p_d1), .out_p1(u_o_p1[g]),
        .out_mf(u_o_mf[g]), .out_mq(u_o_mq[g]), .busy(u_o_busy[g]));
      // the units cut into stages bring their result from their own registers, with the same delay as the tag
      assign u_o_d0[g] = (g == U_LADD) ? s_ladd : (g == U_FADD) ? s_fadd : (g == U_MUL) ? s_fmul : (g == U_DIV) ? s_dv :
                         (g == U_NORM) ? s_norm0 : p_d0;
      assign u_o_d1[g] = (g == U_NORM) ? s_norm1 : p_d1;
    end
  endgenerate

  // memory read data on the bus
  logic        ld_v, ld_v2;
  logic [4:0]  ld_t, ld_t2;
  logic [59:0] ld_d2;
  logic        mb_v;                                   // the memory's bus, port 1
  logic [4:0]  mb_t;
  logic [59:0] mb_d;
  logic        iores_v;                                // the result of a device or character load, on the bus the cycle after it came
  logic [4:0]  iores_t;
  logic [59:0] iores_d;
  logic        io_res_v;                               // (the cycle it came)
  logic [4:0]  io_res_t;
  logic [59:0] io_res_d;

  always_comb begin
    for (int b = 0; b < NB; b++) begin rb_v[b] = 1'b0; rb_t[b] = 5'd0; rb_d[b] = 60'd0; end
    for (int u = 0; u < NU; u++) begin
      rb_v[2*u] = u_o_v[u];
      rb_t[2*u] = {u_o_t[u], 1'b0};
      rb_d[2*u] = u_o_d0[u];
      rb_v[2*u+1] = u_o_v[u] && u_o_p1[u];
      rb_t[2*u+1] = {u_o_t[u], 1'b1};
      rb_d[2*u+1] = {42'd0, u_o_d1[u]};
    end
    // the memory: a read that came back, or a device/character load
    mb_v = 1'b0; mb_t = 5'd0; mb_d = 60'd0;
    if (MEMLAT == 1) begin
      if (ld_v) begin mb_v = 1'b1; mb_t = ld_t; mb_d = drdata; end
    end else begin
      if (ld_v2) begin mb_v = 1'b1; mb_t = ld_t2; mb_d = ld_d2; end
    end
    if (iores_v) begin mb_v = 1'b1; mb_t = iores_t; mb_d = iores_d; end
    rb_v[2*NU+1] = mb_v; rb_t[2*NU+1] = mb_t; rb_d[2*NU+1] = mb_d;
  end

  // register writes: the bus that carries the tag of the reservation; and the bus that carries the tag of a producer a speculative
  // instruction took the register over from (its result goes into the copy)
  logic        rw_v[0:23], shw_v[0:23];
  logic [59:0] rw_d[0:23], shw_d[0:23];
  always_comb begin
    for (int r = 0; r < 24; r++) begin
      logic [60:0] bf, sf;
      bf = 61'd0; sf = 61'd0;
      if (rsv_v[r]) bf = busf(rsv_t[r]);
      if (sh_v[r]) sf = busf(sh_t[r]);
      rw_v[r] = bf[60]; rw_d[r] = bf[59:0];
      shw_v[r] = sf[60]; shw_d[r] = sf[59:0];
    end
  end

  // ------------------------------------------------------------------ memory unit: the queue head
  logic        h_ok, h_pop, h_dev, h_io, h_av, h_dv;
  logic [60:0] h_bf;
  logic [17:0] h_a;
  logic        h_st;
  logic        s_ok, s_dev, s_io;                       // the store at the head, decided on its entry alone
  logic [17:0] s_a;
  logic [59:0] h_d;
  logic [4:0]  h_rt;
  logic        pipe_empty;                              // no BRAM load on its way back
  logic        mem_busy_boot;
  logic        halt_set;
  logic        dev_cool;                                // dev_req must fall for a cycle between two accesses
  logic        rx_take_c, tx_valid_c, fo_valid_c;
  logic [5:0]  tx_char_c;
  logic [59:0] fo_word_c;

  always_comb begin
    // the address from an increment unit and the data of a store are taken straight off the bus in the cycle they appear, not from
    // the entry the cycle after
    h_st = mq_st[mq_head]; h_rt = mq_rt[mq_head];
    h_a = mq_a[mq_head]; h_av = mq_av[mq_head];
    for (int u = U_INC0; u < U_INC0 + NINC; u++)
      if (!mq_av[mq_head] && u_o_v[u] && u_o_mf[u] && u_o_mq[u] == mq_head) begin h_a = u_o_d0[u][17:0]; h_av = 1'b1; end
    h_bf = busf(mq_dt[mq_head]);
    h_d = mq_d[mq_head]; h_dv = mq_dv[mq_head];
    if (mq_dw[mq_head] && h_bf[60]) begin h_d = h_bf[59:0]; h_dv = 1'b1; end
    h_dev = is_dev(h_a); h_io = is_io(h_a);
    // a load.  A speculative entry: a load from memory goes ahead, an I/O access waits for the branch (and nothing in the cycle
    // the guess is undone)
    h_ok = mq_v[mq_head] && h_av && !h_st && (boot == 3'd4) &&
           !(mq_spec[mq_head] && (sq_r || (!commit_r && (h_dev || h_io))));
    // a store.  Its address comes from the entry, never from the bus: the address meets the fetch (f_void), which meets the whole
    // decode, and nothing of that may start at an adder.  So the store's decisions are made on s_a alone, apart from h_ok and h_a.
    // A speculative store waits for the branch.
    s_a = mq_a[mq_head]; s_dev = is_dev(s_a); s_io = is_io(s_a);
    s_ok = mq_v[mq_head] && mq_av[mq_head] && h_st && h_dv && (boot == 3'd4) && !(mq_spec[mq_head] && (sq_r || !commit_r));
    pipe_empty = !ld_v && !ld_v2;
  end

  always_comb begin
    // defaults
    dwe = 1'b0; daddr = '0; dwdata = 60'd0;
    mq_pop = 1'b0;
    st_v = 1'b0; st_a = '0; st_d = 60'd0;
    dev_req = 1'b0; dev_we = 1'b0; dev_off = 13'd0; dev_wdata = 60'd0;
    rx_take_c = 1'b0; tx_valid_c = 1'b0; tx_char_c = 6'd0;
    fo_valid_c = 1'b0; fo_word_c = 60'd0;
    io_res_v = 1'b0; io_res_t = 5'd0; io_res_d = 60'd0;
    halt_set = 1'b0;
    case (boot)
      3'd0: daddr = MEM_AW'(1);
      3'd1: daddr = MEM_AW'(2);
      3'd2: daddr = MEM_AW'(3);
      default: ;
    endcase
    ld_v_next = 1'b0; ld_t_next = 5'd0;
    if (s_ok && !halt_req) begin                          // a store: address s_a from the entry (see above)
      if (s_dev) begin
        if (pipe_empty && !dev_cool) begin
          dev_req = 1'b1; dev_we = 1'b1; dev_off = s_a[12:0]; dev_wdata = h_d;
          if (dev_ack) mq_pop = 1'b1;
        end
      end else if (s_io) begin
        if (s_a[2:0] == 3'd1) begin
          if (tx_ready) begin tx_valid_c = 1'b1; tx_char_c = h_d[5:0]; mq_pop = 1'b1; end
        end else if (s_a[2:0] == 3'd3) begin
          if (fo_ready) begin fo_valid_c = 1'b1; fo_word_c = h_d; mq_pop = 1'b1; end
        end else begin
          mq_pop = 1'b1;                                // IO_FILE, IO_HALT and the rest: handled with the pop
          if (s_a[2:0] == 3'd4) halt_set = 1'b1;
        end
      end else begin
        daddr = MEM_AW'(s_a); dwe = 1'b1; dwdata = h_d; st_v = 1'b1; st_a = MEM_AW'(s_a); st_d = h_d;
        mq_pop = 1'b1;
      end
    end else if (h_ok && !halt_req) begin                 // a load: address h_a, from the entry or the bus
      if (h_dev) begin
        if (pipe_empty && !dev_cool) begin
          dev_req = 1'b1; dev_off = h_a[12:0];
          if (dev_ack) begin mq_pop = 1'b1; io_res_v = 1'b1; io_res_t = h_rt; io_res_d = dev_rdata; end
        end
      end else if (h_io) begin
        if (pipe_empty && rx_valid) begin
          rx_take_c = 1'b1; mq_pop = 1'b1;
          io_res_v = 1'b1; io_res_t = h_rt; io_res_d = rx_eof ? M60 : {54'd0, rx_char};
        end
      end else begin
        daddr = MEM_AW'(h_a); ld_v_next = 1'b1; ld_t_next = h_rt;
        mq_pop = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------ drained
  always_comb begin
    drained = (e_v == '0) && (u_o_busy == '0) && (mq_n == 3'd0) && !ld_v && !ld_v2 && !iores_v && !br_pend && !dv_run && !sq_r && !commit_r;
  end

  // ------------------------------------------------------------------ the clocked part
  always_ff @(posedge clk) begin
    if (reset) begin
      boot <= 3'd0; halted <= 1'b0; fault <= 1'b0; icount <= 64'd0;
      for (int q = 0; q < 8; q++) begin xr[q] <= 60'd0; ar[q] <= 18'd0; br[q] <= 18'd0; end
      rsv_v <= '0; e_v <= '0; sk_v <= '0; sk_wp <= '0;
      for (int t = 0; t < 16; t++) tag_pend[t] <= 2'b00;
      mq_v <= '0; mq_head <= 2'd0; mq_tail <= 2'd0; mq_n <= 3'd0;
      rsv_spec <= '0; tag_spec <= '0; e_spec <= '0; mq_spec <= '0; sq_r <= 1'b0; commit_r <= 1'b0; spec_cnt <= 32'd0; spec_ni <= 16'd0;
      sh_v <= '0;
      dp_w <= 18'd0; dp_s <= 2'd0; dp_nskip <= 5'd0; f_v <= 1'b0; f_drop <= 1'b0; f_a <= '0;
      dr_v <= 1'b0; br_pend <= 1'b0; halt_req <= 1'b0; halt_cnt <= 7'd0;
      ld_v <= 1'b0; ld_v2 <= 1'b0; ld_t <= 5'd0; ld_t2 <= 5'd0; ld_d2 <= 60'd0;
      io_file <= 60'd0; dv_run <= 1'b0; dv_cnt <= 6'd0; dev_cool <= 1'b0; iores_v <= 1'b0;
      rx_take <= 1'b0; tx_valid <= 1'b0; tx_char <= 6'd0; fo_valid <= 1'b0; fo_word <= 60'd0; fo_name <= 60'd0;
    end else begin
      // ---- boot block: entry point, B5 = B6, B4
      case (boot)
        3'd0: boot <= 3'd1;
        3'd1: begin dp_w <= drdata[17:0]; boot <= 3'd2; end
        3'd2: begin br[5] <= drdata[17:0]; br[6] <= drdata[17:0]; boot <= 3'd3; end
        3'd3: begin br[4] <= drdata[17:0]; xr[7] <= 60'o100; boot <= 3'd4; end
        default: ;
      endcase

      // ---- instruction fetch: the word that came, then a new request
      if (f_v && !f_drop && !f_void) begin
        sk_d[fill_i] <= ret_data; sk_a[fill_i] <= f_a; sk_v[fill_i] <= 1'b1;
        sk_wp <= fill_i + 1'b1;
      end
      // a store into a word of the stack: write through (not into the entry that is being replaced this cycle: ret_data has the store)
      if (st_v) for (int n = 0; n < NSK; n++) if (sk_v[n] && sk_a[n] == st_a && !(f_v && !f_drop && !f_void && n == int'(fill_i))) sk_d[n] <= st_d;
      // an RJ: the word it calls gets the return jump from the memory queue later; until then the stack must not hold it, so that a
      // JP back to it is fetched again (and served from the queue, see ret_data)
      for (int s = 0; s < 2; s++) if (issue_fire[s] && D[s].rj) begin
        for (int n = 0; n < NSK; n++) if (sk_v[n] && sk_a[n] == MEM_AW'(dr[s].K)) sk_v[n] <= 1'b0;
        if (f_v && !f_drop && !f_void && f_a == MEM_AW'(dr[s].K)) sk_v[fill_i] <= 1'b0;
      end
      f_v <= 1'b0; f_drop <= 1'b0;
      if (boot == 3'd4 && want_v) begin
        f_v <= 1'b1; f_a <= want_a;
        f_drop <= st_v && (st_a == want_a);
      end

      // ---- decode into the decode register: the slots that issued are freed (slot 1 moves down), decode fills from the window
      if (redirect_v) begin
        dp_w <= redirect_t; dp_s <= redirect_s; dr_v <= 2'b00; dp_nskip <= 5'd0;
      end else begin
        if (!keep[0] && keep[1]) begin dr[0] <= dr[1]; dr_v[0] <= 1'b1; dr_v[1] <= 1'b0; end
        else begin
          if (!keep[0]) dr_v[0] <= 1'b0;
          if (!keep[1]) dr_v[1] <= 1'b0;
        end
        if (ncons != 2'd0) begin
          if (!keep[0] && !keep[1]) begin
            dr[0] <= candA; dr_v[0] <= 1'b1;
            if (ncons == 2'd2) begin dr[1] <= candB; dr_v[1] <= 1'b1; end
          end else begin dr[1] <= candA; dr_v[1] <= 1'b1; end         // one slot stays (slot 0, or slot 1 moved down): A behind it
          // where decode goes on: the target of the last instruction taken if it is followed, else after it
          if (ncons == 2'd2) begin
            if (d_takepB) begin dp_w <= d_tgtB; dp_s <= 2'd0; end else begin dp_w <= ndB_w; dp_s <= ndB_s; end
            dp_nskip <= trailB;
          end else begin
            if (d_takepA) begin dp_w <= d_tgtA; dp_s <= 2'd0; end else begin dp_w <= ndA_w; dp_s <= ndA_s; end
            dp_nskip <= trailA;
          end
        end else if (free_ != 2'd0 && boot == 3'd4 && dec_hit && !foundA) begin       // only no-operations left: the next word
          dp_nskip <= dp_nskip + skipA; dp_w <= dp_w + 18'd1; dp_s <= 2'd0;
        end
      end

      // ---- registers and reservations (not from a speculative instruction in the cycle its branch turns out wrong, nor the one after).
      // A wrong guess brings the copy back first; the results of the instructions before the branch then go into both
      if (sq_r) for (int q = 0; q < 8; q++) begin xr[q] <= xs[q]; ar[q] <= as[q]; br[q] <= bs[q]; end
      if (ckpt_now)                                                                           // the copy, as the branch goes in
        for (int q = 0; q < 8; q++) begin xs[q] <= xr[q]; as[q] <= ar[q]; bs[q] <= br[q]; end
      // the copy takes every result that is not speculative: in the cycle the branch goes in and in the cycle a right guess is
      // kept, the marks still set belong to instructions before the branch
      // (a speculative result arriving in the cycle its branch turns out wrong may be written: the copy brought back next cycle
      // undoes it; only the restore cycle itself is gated, which keeps the branch decision off the register write enables)
      // the result of a producer taken over by a speculative instruction: into the copy (and, if the guess is being undone this cycle,
      // into the live register the copy comes back into)
      for (int r = 0; r < 24; r++) if (shw_v[r]) begin
        sh_v[r] <= 1'b0;
        if (r < 8) begin xs[r] <= shw_d[r]; if (sq_r) xr[r] <= shw_d[r]; end
        else if (r < 16) begin as[r-8] <= shw_d[r][17:0]; if (sq_r) ar[r-8] <= shw_d[r][17:0]; end
        else if (r != 16) begin bs[r-16] <= shw_d[r][17:0]; if (sq_r) br[r-16] <= shw_d[r][17:0]; end
      end
      for (int r = 0; r < 24; r++) if (rw_v[r] && !(sq_r && rsv_spec[r])) begin
        logic to_copy;
        to_copy = !rsv_spec[r] || commit_r || ckpt_now;
        rsv_v[r] <= 1'b0;
        if (r < 8) begin xr[r] <= rw_d[r]; if (to_copy) xs[r] <= rw_d[r]; end
        else if (r < 16) begin ar[r-8] <= rw_d[r][17:0]; if (to_copy) as[r-8] <= rw_d[r][17:0]; end
        else if (r != 16) begin br[r-16] <= rw_d[r][17:0]; if (to_copy) bs[r-16] <= rw_d[r][17:0]; end
      end
      // ---- units: operand capture, launch
      for (int u = 0; u < NU; u++) begin
        if (e_v[u]) begin
          if (e_w0[u]) begin
            logic [60:0] bf; bf = busf(e_t0[u]);
            if (bf[60]) begin e_s0[u] <= bf[59:0]; e_w0[u] <= 1'b0; end
          end
          if (e_w1[u]) begin
            logic [60:0] bf; bf = busf(e_t1[u]);
            if (bf[60]) begin e_s1[u] <= bf[59:0]; e_w1[u] <= 1'b0; end
          end
          if (launch[u]) e_v[u] <= 1'b0;
        end
      end
      // ---- the branch was decided: undo (sq_r) or keep (commit_r) what was issued after it.  Nothing issues during sq_r; the marks
      // cleared here are those of the instructions before (what issues in the commit cycle sets its marks below, after this)
      sq_r <= squash_now; commit_r <= SPEC && launch[U_BR] && !squash_now;
      if (sq_r) begin
        for (int u = 0; u < NU; u++) if (e_spec[u]) e_v[u] <= 1'b0;
        // a reservation made after the branch goes: back to the producer before it that is still to write, if there is one
        for (int r = 0; r < 24; r++) if (rsv_spec[r]) begin rsv_v[r] <= sh_v[r] && !shw_v[r]; rsv_t[r] <= sh_t[r]; end
        for (int q = 0; q < Q; q++) if (mq_spec[q]) mq_v[q] <= 1'b0;
        if (e_spec[U_DIV]) dv_run <= 1'b0;
      end
      if (sq_r || commit_r) begin e_spec <= '0; rsv_spec <= '0; mq_spec <= '0; tag_spec <= '0; sh_v <= '0; end
      spec_cnt <= ((sq_r || commit_r) ? 32'd0 : spec_cnt) + 32'(iss_spec_cnt);
      spec_ni <= ((sq_r || commit_r) ? 16'd0 : spec_ni) + 16'(iss_spec_ni);

      // ---- issue: slot 0, then slot 1 (which only issues with slot 0, so its reservations are the later ones)
      for (int s = 0; s < 2; s++) if (issue_fire[s]) begin
        logic [3:0] t;
        logic [1:0] mqs;
        logic sp;
        t = tg[s]; mqs = mq_tail + ((s == 1 && need_mq[0]) ? 2'd1 : 2'd0); sp = spec_is[s];
        // reservations and tags (tag_pend is set below, after the bus clears it)
        if (need_tag[s]) begin
          tag_spec[t] <= sp;
          for (int d = 0; d < 3; d++) begin                       // the destinations: d0, d1, the X register of a load
            logic dv;
            logic [4:0] dreg, dtag;
            dv = (d == 0) ? D[s].d0v : (d == 1) ? D[s].d1v : D[s].mld;
            dreg = (d == 0) ? D[s].d0r : (d == 1) ? D[s].d1r : rx_(dr[s].i);
            dtag = {t, (d != 0)};
            if (dv) begin
              // taken over from an instruction before the branch that has not written yet: its result keeps a way into the copy
              // (not if it writes now; in the cycle a right guess is kept, the marks still set are those of instructions before
              // this branch: they count as not speculative)
              if (sp && rsv_v[dreg] && !(rsv_spec[dreg] && !commit_r) && !rw_v[dreg]) begin sh_v[dreg] <= 1'b1; sh_t[dreg] <= rsv_t[dreg]; end
              rsv_v[dreg] <= 1'b1; rsv_t[dreg] <= dtag; rsv_spec[dreg] <= sp;
            end
          end
        end
        // into a unit
        if (D[s].uk != UK_NONE && !br_early[s]) begin
          e_v[sel_u[s]] <= 1'b1; e_spec[sel_u[s]] <= sp;
          e_f[sel_u[s]] <= dr[s].f; e_ijk[sel_u[s]] <= {dr[s].i, dr[s].j, dr[s].k}; e_K[sel_u[s]] <= dr[s].K; e_tag[sel_u[s]] <= t;
          e_d0v[sel_u[s]] <= D[s].d0v; e_d1v[sel_u[s]] <= D[s].d1v;
          e_s0[sel_u[s]] <= o_v[s][0]; e_w0[sel_u[s]] <= o_w[s][0]; e_t0[sel_u[s]] <= o_t[s][0];
          e_s1[sel_u[s]] <= o_v[s][1]; e_w1[sel_u[s]] <= o_w[s][1]; e_t1[sel_u[s]] <= o_t[s][1];
          e_mf[sel_u[s]] <= (D[s].mld || D[s].mst) && !ag_ok[s]; e_mq[sel_u[s]] <= mqs;
          e_wd[sel_u[s]] <= dr[s].w;
          if (D[s].uk == UK_BR) begin br_pend <= 1'b1; bu_pred <= dr[s].pred; bu_fw <= dr[s].fw; bu_fs <= dr[s].fs; bu_idx <= dr[s].idx; end
        end
        // the memory queue
        if (need_mq[s]) begin
          mq_v[mqs] <= 1'b1; mq_st[mqs] <= D[s].mst || D[s].rj; mq_spec[mqs] <= sp;
          mq_av[mqs] <= D[s].rj || ag_ok[s]; mq_a[mqs] <= ag_ok[s] ? ag_sum[s] : dr[s].K;
          mq_rt[mqs] <= {t, 1'b1};
          if (D[s].rj) begin
            mq_dv[mqs] <= 1'b1; mq_dw[mqs] <= 1'b0;
            mq_d[mqs] <= {6'o04, 6'o00, 18'(dr[s].w + 18'd1), 30'd0};
          end else if (D[s].mst) begin
            mq_dv[mqs] <= !o_w[s][2]; mq_dw[mqs] <= o_w[s][2]; mq_dt[mqs] <= o_t[s][2]; mq_d[mqs] <= o_v[s][2];
          end else begin
            mq_dv[mqs] <= 1'b0; mq_dw[mqs] <= 1'b0;
          end
        end
        if (D[s].special) begin halted <= 1'b1; fault <= 1'b1; end
      end
      icount <= icount + 64'(iss_icnt) - (sq_r ? 64'(spec_cnt) : 64'd0);
      mq_tail <= sq_r ? mq_tail - mq_nspec[1:0] : mq_tail + iss_nmq;             // undone: the speculative entries are the newest
      mq_n <= mq_n + 3'(iss_nmq) - (mq_pop ? 3'd1 : 3'd0) - (sq_r ? mq_nspec : 3'd0);
      if (mq_pop) begin mq_v[mq_head] <= 1'b0; mq_head <= mq_head + 2'd1; end

      // an increment result that is a memory address
      for (int u = U_INC0; u < U_INC0 + NINC; u++) begin
        if (u_o_v[u] && u_o_mf[u]) begin
          mq_a[u_o_mq[u]] <= u_o_d0[u][17:0]; mq_av[u_o_mq[u]] <= 1'b1;
        end
      end
      // data of a store arrives
      for (int q = 0; q < Q; q++) if (mq_v[q] && mq_dw[q]) begin
        logic [60:0] bf; bf = busf(mq_dt[q]);
        if (bf[60]) begin mq_d[q] <= bf[59:0]; mq_dw[q] <= 1'b0; mq_dv[q] <= 1'b1; end
      end

      // ---- the divider
      if (e_v[U_DIV] && !e_w0[U_DIV] && !e_w1[U_DIV]) begin
        if (!dv_run && !dv_special_v && !(sq_r && e_spec[U_DIV])) begin
          dv_run <= 1'b1; dv_cnt <= 6'd0; dv_q <= 51'd0; dv_r <= 50'd0;
          dv_neg <= dv_x.neg ^ dv_y.neg; dv_round <= e_f[U_DIV][0];
          dv_xc <= dv_x.c << clz48(dv_x.c); dv_yc <= dv_y.c << clz48(dv_y.c);
          dv_e <= int'(dv_x.e) - clz48(dv_x.c) - (int'(dv_y.e) - clz48(dv_y.c)) - 50;
        end else if (dv_run) begin
          if (dv_cnt != 6'd51) begin
            dv_q <= {dv_q[49:0], dv_qb}; dv_r <= dv_qb ? dv_rr - {2'b00, dv_yc} : dv_rr[49:0];
            dv_cnt <= dv_cnt + 6'd1;
          end else dv_run <= 1'b0;
        end
      end

      // ---- the branch unit
      if (launch[U_BR]) begin
        br_pend <= 1'b0;
      end

      // tags are given back when their results are on the bus, or when the instruction is undone; the tag given out at issue is
      // set last (a load undone while on its way back clears its old tag in the cycle it could be given out again)
      for (int b = 0; b < NB; b++) if (rb_v[b]) begin
        tag_pend[rb_t[b][4:1]][rb_t[b][0]] <= 1'b0;
      end
      if (sq_r) for (int t = 0; t < 16; t++) if (tag_spec[t]) tag_pend[t] <= 2'b00;
      for (int s = 0; s < 2; s++) if (issue_fire[s] && need_tag[s]) tag_pend[tg[s]] <= {D[s].d1v || D[s].mld, D[s].d0v};

      // ---- loads coming back
      ld_v <= ld_v_next; ld_t <= ld_t_next;
      ld_v2 <= ld_v; ld_t2 <= ld_t; ld_d2 <= drdata;

      // ---- strobes to the outside
      rx_take <= rx_take_c; tx_valid <= tx_valid_c; tx_char <= tx_char_c;
      fo_valid <= fo_valid_c; fo_word <= fo_word_c; fo_name <= io_file;
      dev_cool <= dev_req && dev_ack;
      iores_v <= io_res_v; iores_t <= io_res_t; iores_d <= io_res_d;
      // ---- the stop
      if (halt_set) halt_req <= 1'b1;
      if (halt_req) begin
        halt_cnt <= halt_cnt + 7'd1;
        if (halt_cnt == HALT_WAIT[6:0]) halted <= 1'b1;
      end
      if (mq_pop && s_ok && s_io && s_a[2:0] == 3'd2) io_file <= h_d;
    end
  end

  // redirect: the branch unit resolved a taken branch, or a jump at issue
  always_comb begin
    redirect_v = 1'b0; redirect_t = 18'd0; redirect_s = 2'd0;
    if (jump_now) begin redirect_v = 1'b1; redirect_t = jump_t; redirect_s = jump_s; end
    if (launch[U_BR] && (br_taken != bu_pred)) begin
      redirect_v = 1'b1; redirect_t = br_taken ? br_tgt : bu_fw; redirect_s = br_taken ? 2'd0 : bu_fs;
    end
  end

  // the history table learns from every conditional branch that is decided
  logic              bht_we, bht_tk;
  logic [BHT_AW-1:0] bht_i;
  always_comb begin
    bht_we = 1'b0; bht_tk = 1'b0; bht_i = dr[0].idx;
    for (int s = 0; s < 2; s++)                                          // two decided at issue: one write is lost
      if (issue_fire[s] && br_early[s] && dr[s].f >= 6'o03) begin bht_we = 1'b1; bht_tk = br_e_tk[s]; bht_i = dr[s].idx; end
    if (launch[U_BR] && e_f[U_BR] >= 6'o03) begin bht_we = 1'b1; bht_tk = br_taken; bht_i = bu_idx; end
  end
  always_ff @(posedge clk) if (bht_we && !reset) begin
    if (bht_tk) bht[bht_i] <= (bht[bht_i] == 2'b11) ? 2'b11 : bht[bht_i] + 2'b01;
    else bht[bht_i] <= (bht[bht_i] == 2'b00) ? 2'b00 : bht[bht_i] - 2'b01;
  end

  // ---- performance counters (not used on the board: the tools remove them)
  //  0 cycles   1 issued   2 decode register empty   3 held for a branch (SPEC: a branch waits for the branch unit, or the undo cycle)
  //  4 unit busy   5 destination reserved   6 no tag   7 memory queue full   8 cycles with two instructions issued   9 redirects
  //  10 stack misses (decode waited for a word)   11 decode register empty within 3 cycles of a redirect
  //  12 memory head blocked: no address yet  13 head waits for data   14 branches decided in the branch unit   15 of them wrong
  logic [31:0] pc_[0:15];
  logic [2:0]  since_rd;
  always_ff @(posedge clk) begin
    if (reset) begin for (int q = 0; q < 16; q++) pc_[q] <= 32'd0; since_rd <= 3'd7; end
    else if (boot == 3'd4 && !halted) begin
      pc_[0] <= pc_[0] + 1;
      pc_[1] <= pc_[1] + 32'(issue_fire[0]) + 32'(issue_fire[1]);
      if (issue_fire[1]) pc_[8] <= pc_[8] + 1;
      if (!dr_v[0]) pc_[2] <= pc_[2] + 1;
      else if (!issue_fire[0]) begin
        if (SPEC ? (sq_r || (D[0].uk == UK_BR && !br_early[0] && e_v[U_BR])) : br_pend) pc_[3] <= pc_[3] + 1;
        else if (!unit_ok[0]) pc_[4] <= pc_[4] + 1;
        else if (!dest_ok[0]) pc_[5] <= pc_[5] + 1;
        else if (need_tag[0] && !tg_ok[0]) pc_[6] <= pc_[6] + 1;
        else if (!mq_okv[0]) pc_[7] <= pc_[7] + 1;
      end
      if (redirect_v) pc_[9] <= pc_[9] + 1;
      if (!dr_v[0] && !dec_hit) pc_[10] <= pc_[10] + 1;
      since_rd <= redirect_v ? 3'd0 : (since_rd == 3'd7 ? 3'd7 : since_rd + 3'd1);
      if (!dr_v[0] && since_rd < 3'd4) pc_[11] <= pc_[11] + 1;
      if (launch[U_BR]) pc_[14] <= pc_[14] + 1;
      if (launch[U_BR] && br_taken != bu_pred) pc_[15] <= pc_[15] + 1;
      if (mq_v[mq_head] && !mq_av[mq_head]) pc_[12] <= pc_[12] + 1;
      if (mq_v[mq_head] && mq_av[mq_head] && mq_st[mq_head] && !mq_dv[mq_head]) pc_[13] <= pc_[13] + 1;
    end
  end
  always_comb begin
    for (int q = 0; q < 16; q++) dbg_perf[32*q +: 32] = pc_[q];
  end

  assign dbg_pc = dp_w;
  always_comb begin
    for (int q = 0; q < 8; q++) begin
      dbg_x[60*q +: 60] = xr[q]; dbg_a[18*q +: 18] = ar[q]; dbg_b[18*q +: 18] = br[q];
    end
  end
`ifndef SYNTHESIS
  // where the branch unit waits: by the unit that makes the operand it needs (printed when the simulation ends)
  logic [3:0] tag_u[0:15];
  longint hold_by[0:NU];
  longint hold_total;
  initial begin for (int q = 0; q <= NU; q++) hold_by[q] = 0; hold_total = 0; end
  always @(posedge clk) begin
    for (int s = 0; s < 2; s++) if (!reset && issue_fire[s] && need_tag[s]) tag_u[tg[s]] <= sel_u[s][3:0];
    if (!reset && boot == 3'd4 && br_pend && e_v[U_BR] && !launch[U_BR]) begin
      hold_total <= hold_total + 1;
      if (e_w0[U_BR]) hold_by[(e_t0[U_BR][4:1] == 4'd0 && 1'b0) ? 0 : (tag_known(e_t0[U_BR]) ? tag_u[e_t0[U_BR][4:1]] : NU)] <= hold_by[(tag_known(e_t0[U_BR]) ? tag_u[e_t0[U_BR][4:1]] : NU)] + 1;
      else if (e_w1[U_BR]) hold_by[(tag_known(e_t1[U_BR]) ? tag_u[e_t1[U_BR][4:1]] : NU)] <= hold_by[(tag_known(e_t1[U_BR]) ? tag_u[e_t1[U_BR][4:1]] : NU)] + 1;
    end
  end
  function automatic logic tag_known(input logic [4:0] t); tag_known = 1'b1; endfunction
  // and where slot 0 waits for a unit, by the kind of unit (UK_*)
  longint busy_by[0:15];
  initial for (int q = 0; q < 16; q++) busy_by[q] = 0;
  always @(posedge clk) if (!reset && boot == 3'd4 && dr_v[0] && !issue_fire[0] && !hold && !unit_ok[0]) busy_by[D[0].uk] <= busy_by[D[0].uk] + 1;
  final begin
    $fwrite(32'h8000_0002, "branch unit waits (cycles, by the unit that makes the operand): total %0d\n", hold_total);
    for (int q = 0; q <= NU; q++) if (hold_by[q] != 0) $fwrite(32'h8000_0002, "   unit %0d: %0d\n", q, hold_by[q]);
    $fwrite(32'h8000_0002, "slot 0 waits for a unit, by unit kind (0 br 1 bool 2 shift 3 ladd 4 fadd 5 mul 6 div 7 inc 9 norm):\n");
    for (int q = 0; q < 16; q++) if (busy_by[q] != 0) $fwrite(32'h8000_0002, "   kind %0d: %0d\n", q, busy_by[q]);
  end
  // +trace: one line per issued instruction, "P/slot", as cdcemu -t and the sequential core print (no-operations are not issued)
  logic trace_en;
  initial trace_en = $test$plusargs("trace");
  always @(posedge clk) if (!reset && trace_en) for (int s = 0; s < 2; s++) if (issue_fire[s]) $display("T %o/%0d  c=%0d f=%o s=%0d t=%0d u=%0d w0=%b/%0d w1=%b/%0d", dr[s].w, dr[s].s, pc_[0], dr[s].f, s, tg[s], sel_u[s], o_w[s][0], o_t[s][0], o_w[s][1], o_t[s][1]);
  // +tracereg: every write of X2 (live and copy) and the restore
  logic trace_reg;
  initial trace_reg = $test$plusargs("tracereg");
  always @(posedge clk) if (!reset && trace_reg) begin
    if (rw_v[2] && !(sq_r && rsv_spec[2])) $display("W c=%0d X2 <= %020o tag=%0d spec=%b sq_r=%b commit=%b ckpt=%b", pc_[0], rw_d[2], rsv_t[2], rsv_spec[2], sq_r, commit_r, ckpt_now);
    if (rw_v[2] && (sq_r && rsv_spec[2])) $display("w c=%0d X2 write gated %020o tag=%0d", pc_[0], rw_d[2], rsv_t[2]);
    if (shw_v[2]) $display("H c=%0d xs2 <= %020o (sh tag %0d) sq_r=%b", pc_[0], shw_d[2], sh_t[2], sq_r);
    if (sq_r) $display("X c=%0d restore X2 <= xs2 %020o rsv_spec=%b sh_v=%b sh_t=%0d", pc_[0], xs[2], rsv_spec[2], sh_v[2], sh_t[2]);
    if (ckpt_now) $display("C c=%0d ckpt xs2 <= xr2 %020o", pc_[0], xr[2]);
    for (int s = 0; s < 2; s++) if (issue_fire[s] && ((D[s].d0v && D[s].d0r == 5'd2) || (D[s].mld && dr[s].i == 3'd2)))
      $display("I c=%0d slot %0d reserves X2 tag=%0d spec=%b (was v=%b t=%0d spec=%b rw_v=%b)", pc_[0], s, tg[s], spec_is[s], rsv_v[2], rsv_t[2], rsv_spec[2], rw_v[2]);
  end
  // "K n": the last n T lines were issued on a wrong guess and are undone
  always @(posedge clk) if (!reset && trace_en && sq_r) $display("K %0d  c=%0d", spec_ni, pc_[0]);
  logic dbg_prev_issue;
  always @(posedge clk) dbg_prev_issue <= issue_fire[0];
  always @(posedge clk) if (!reset && trace_en && boot==3'd4 && !dr_v[0]) $display("E c=%0d dp=%o/%0d hit=%b found=%b redir=%b prev_issue=%b fv=%b fa=%o wantv=%b", pc_[0], dp_w, dp_s, dec_hit, foundA, redirect_v, dbg_prev_issue, f_v, f_a, want_v);
  always @(posedge clk) if (!reset && trace_en && st_v) $display("S %o <= %020o  (f_v=%b f_a=%o) c=%0d", st_a, st_d, f_v, f_a, pc_[0]);
  always @(posedge clk) if (!reset && trace_en && mq_pop) $display("M c=%0d pop head=%0d st=%b a=%o spec=%b tail=%0d n=%0d", pc_[0], mq_head, h_st, h_a, mq_spec[mq_head], mq_tail, mq_n);
  always @(posedge clk) if (!reset && trace_en) for (int s = 0; s < 2; s++) if (issue_fire[s] && need_mq[s]) $display("Q c=%0d slot %0d -> mq %0d (tail=%0d n=%0d)", pc_[0], s, mq_tail + ((s == 1 && need_mq[0]) ? 2'd1 : 2'd0), mq_tail, mq_n);
  always @(posedge clk) if (!reset && trace_en && redirect_v) $display("R %o jump_now=%b%b br_early=%b launchBR=%b taken=%b e_f=%o dr_f=%o dr_K=%o drv=%b early_tk=%b", redirect_t, jump_now0, jump_now1, br_early[0], launch[U_BR], br_taken, e_f[U_BR], dr[0].f, dr[0].K, dr_v, br_e_tk[0]);
`endif
endmodule


// a delay line for a result: LAT-1 register stages after the unit; LAT = 1 is a wire.  A result marked speculative is dropped from
// the line on kill, and loses the mark on keep
module sb_pipe #(parameter int LAT = 1) (
  input  logic clk, input logic reset, input logic kill, input logic keep,
  input  logic in_v, input logic in_spec, input logic [3:0] in_t, input logic [59:0] in_d0, input logic [17:0] in_d1, input logic in_p1,
  input  logic in_mf, input logic [1:0] in_mq,
  output logic out_v, output logic [3:0] out_t, output logic [59:0] out_d0, output logic [17:0] out_d1, output logic out_p1,
  output logic out_mf, output logic [1:0] out_mq,
  output logic busy
);
  localparam int W = 1 + 4 + 60 + 18 + 1 + 1 + 2;
  logic [W-1:0] vin;
  assign vin = {in_v, in_t, in_d0, in_d1, in_p1, in_mf, in_mq};
  generate
    if (LAT <= 1) begin : g_wire
      assign {out_v, out_t, out_d0, out_d1, out_p1, out_mf, out_mq} = vin;
      assign busy = 1'b0;
    end else begin : g_regs
      logic [W-1:0] st[0:LAT-2];
      logic [LAT-2:0] sp;
      always_ff @(posedge clk) begin
        if (reset) begin for (int s = 0; s < LAT - 1; s++) st[s] <= '0; sp <= '0; end
        else begin
          st[0] <= vin; sp[0] <= in_spec && !keep;
          for (int s = 1; s < LAT - 1; s++) begin st[s] <= st[s-1]; sp[s] <= sp[s-1] && !keep; end
          if (kill) for (int s = 1; s < LAT - 1; s++) if (sp[s-1]) st[s][W-1] <= 1'b0;
        end
      end
      assign {out_v, out_t, out_d0, out_d1, out_p1, out_mf, out_mq} = st[LAT-2];
      always_comb begin
        busy = 1'b0;
        for (int s = 0; s < LAT - 1; s++) busy = busy | st[s][W-1];
      end
    end
  endgenerate
endmodule


// ---- the data paths of the units that are cut into stages: each has the latency written next to it (the tag goes through sb_pipe
// with the same one).  The functions are in cdc_pkg.sv and are checked against the one-cycle ones by tests/fpstage_tb.sv.

// long add: both sums, then the choice and the correction of an all-ones result.  Latency 2
module sb_ladd (input logic clk, input logic [59:0] a, input logic [59:0] b, input logic sub, output logic [59:0] r);
  import cdc_pkg::*;
  add1_t t1;
  always_ff @(posedge clk) t1 <= add_s1(a, sub ? ~b : b);
  assign r = add_s2(t1);
endmodule

// floating add: unpack and order, align and add, find the top bit, round and shift, pack.  Latency 5
module sb_fadd (input logic clk, input logic [59:0] a, input logic [59:0] b, input logic [5:0] f, output logic [59:0] r);
  import cdc_pkg::*;
  fa1_t s1; nrm_t s2; fn1_t s3; fn2_t s4;
  logic r1, r2;
  always_ff @(posedge clk) begin
    s1 <= fa_s1(a, b, f[0]); r1 <= f[2];
    s2 <= fa_s2(s1);         r2 <= r1;
    s3 <= fn_s1(s2, r2);
    s4 <= fn_s2(s3);
  end
  assign r = fn_s3(s4);
endmodule

// floating multiply and the low half of the product (DX): unpack, the 48 x 48 multiply in the DSP blocks (3 stages), then normalise
// and pack, or the low half.  Latency 7
module sb_fmul (input logic clk, input logic [59:0] a, input logic [59:0] b, input logic [5:0] f, output logic [59:0] r);
  import cdc_pkg::*;
  typedef struct packed { logic neg; logic signed [15:0] es; logic isd, ib, rnd; } mm_t;
  typedef struct packed { logic [95:0] p; logic [6:0] pp; logic neg; logic signed [15:0] es; logic ib, pz, isd; } dm_t;
  fl_t x, y;
  logic [47:0] xc, yc;
  mm_t m1, m2, m3, m4, m5, m6;
  (* use_dsp = "yes" *) logic [95:0] p1, p2, p3;
  fn1_t n1; fn2_t n2;
  dm_t d1;
  logic [59:0] d2;
  always_comb begin x = funpack(a); y = funpack(b); end
  always_ff @(posedge clk) begin
    xc <= x.c; yc <= y.c;
    m1.neg <= x.neg ^ y.neg; m1.es <= 16'(int'(x.e) + int'(y.e)); m1.isd <= (f == 6'o42);
    m1.ib <= (x.e == -16'sd1024) && (y.e == -16'sd1024); m1.rnd <= f[0];
    p1 <= {48'd0, xc} * {48'd0, yc}; m2 <= m1;
    p2 <= p1; m3 <= m2;
    p3 <= p2; m4 <= m3;
    // stage 5: the top bit of the product
    n1 <= fn_s1('{zero: 1'b0, neg: m4.neg, m: NW'(p3), e: m4.es}, m4.rnd);
    d1 <= '{p: p3, pp: 7'(msbn(NW'(p3))), neg: m4.neg, es: m4.es, ib: m4.ib, pz: (p3 == 96'd0), isd: m4.isd}; m5 <= m4;
    // stage 6: round and shift / the low half
    n2 <= fn_s2(n1);
    if (d1.ib) d2 <= d1.neg ? ~{12'd0, d1.p[47:0]} : {12'd0, d1.p[47:0]};
    else if (d1.pz) d2 <= 60'd0;
    else begin
      logic [95:0] lo;
      int sh;
      sh = int'(d1.pp) - 47; if (sh < 0) sh = 0;
      lo = d1.p & ((96'd1 << sh) - 96'd1);
      d2 <= fpack(d1.neg, d1.es, lo[47:0]);
    end
    m6 <= m5;
  end
  assign r = m6.isd ? d2 : fn_s3(n2);
endmodule

// the end of a division: the quotient (51 bits, from the divider) rounded, shifted and packed; or a result that needs no
// normalising (division by zero, zero divided).  Latency 3 from the last quotient bit
module sb_dvout (input logic clk, input logic run, input cdc_pkg::nrm_t n, input logic round, input logic [59:0] sp_d,
                 output logic [59:0] r);
  import cdc_pkg::*;
  fn1_t f1; fn2_t f2;
  logic o1, o2;
  logic [59:0] d1, d2;
  always_ff @(posedge clk) begin
    f1 <= fn_s1(n, round); o1 <= !run; d1 <= sp_d;
    f2 <= fn_s2(f1);       o2 <= o1;   d2 <= d1;
  end
  assign r = o2 ? d2 : fn_s3(f2);
endmodule

// normalise (NX, ZX), unpack (UX), pack (PX), count ones (CX).  Latency 3
module sb_norm (input logic clk, input logic [59:0] w0, input logic [59:0] w1, input logic [5:0] f,
                output logic [59:0] r0, output logic [17:0] r1);
  import cdc_pkg::*;
  nx1_t nx;
  logic [59:0] uxc, px;
  logic [17:0] uxe;
  logic [23:0] pop;
  logic [5:0] f1;
  logic [59:0] q0;
  logic [17:0] q1;
  always_ff @(posedge clk) begin
    nx <= nx_s1(w0); uxc <= ux_coef(w0); uxe <= ux_exp(w0); px <= px_result(w1, w0[17:0]); pop <= pop_s1(w0); f1 <= f;
    q1 <= 18'd0;
    case (f1)
      6'o24, 6'o25: begin q0 <= nx_s2(nx); q1 <= nx.zero ? 18'd0 : 18'(nx.n); end
      6'o26: begin q0 <= uxc; q1 <= uxe; end
      6'o27: q0 <= px;
      default: q0 <= pop_s2(pop);
    endcase
  end
  assign r0 = q0; assign r1 = q1;
endmodule
