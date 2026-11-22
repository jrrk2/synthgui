// Salt-aware DES (run-time salt): include after crack2_des.svh.
// crypt's salt applied to the expansion: swap expanded bits k and k+24 for salt bit k
function automatic logic [1:48] exp_salt(input logic [1:32] r, input logic [11:0] s);
    logic [1:48] e, o;
    e = des_e(r);
    o = e;
    for (int k = 0; k < 12; k++) begin
        o[k + 1]  = s[k] ? e[k + 25] : e[k + 1];
        o[k + 25] = s[k] ? e[k + 1] : e[k + 25];
    end
    return o;
endfunction
function automatic logic [1:32] des_f_s(input logic [1:32] r, input logic [1:48] k,
                                        input logic [11:0] s);
    logic [1:48] x;
    x = exp_salt(r, s) ^ k;
    return des_p({des_s1(x[1:6]), des_s2(x[7:12]), des_s3(x[13:18]), des_s4(x[19:24]),
                  des_s5(x[25:30]), des_s6(x[31:36]), des_s7(x[37:42]), des_s8(x[43:48])});
endfunction
function automatic logic [1:64] des16_s(input logic [1:64] lr, input logic [1:56] cd,
                                        input logic [11:0] s);
    logic [1:32] l, r, t;
    l = lr[1:32];
    r = lr[33:64];
    t = l ^ des_f_s(r, des_k1(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k2(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k3(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k4(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k5(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k6(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k7(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k8(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k9(cd), s);  l = r; r = t;
    t = l ^ des_f_s(r, des_k10(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k11(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k12(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k13(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k14(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k15(cd), s); l = r; r = t;
    t = l ^ des_f_s(r, des_k16(cd), s); l = r; r = t;
    return {r, l};
endfunction
