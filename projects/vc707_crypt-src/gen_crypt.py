#!/usr/bin/env python3
"""UNIX V7 crypt(3): a reference model and the SystemVerilog it is built from.

crypt(pw, salt) sets the DES key from the first eight characters of pw (seven bits
each, MSB first), swaps entries i and i+24 of the E table for each set bit of the
two salt characters, encrypts a zero block 25 times with that modified DES, and
prints the 66 bits (64 and two zeros) as eleven characters of ./0-9A-Za-z after
the salt.  /usr/src/libc/gen/crypt.c in V7; glibc's DES crypt is the same function.

  gen_crypt.py svh   <out.svh>       the DES functions, the salt's E table built in
  gen_crypt.py check [n]             the model against the host's libcrypt
  gen_crypt.py expect <out.svh> [n]  the sum of the first n hashes the engine makes
  gen_crypt.py crack <out.svh> <pw> [len]  target for the search demo: crypt(pw) and the
                                     lowercase length to sweep (pw must be that long)
"""
import ctypes
import sys

ALPHA = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
SALT = "ab"
ITER = 25
NHASH = 1 << 20

IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
      62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
      57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
      61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
      38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
      36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
      34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
     16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
     2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3,
       60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6,
       61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
       41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def salt_e(salt):
    """E with entries i and i+24 swapped for each set bit of the salt (crypt.c)."""
    e = list(E)
    for i in range(2):
        c = ord(salt[i])
        if c > ord('Z'):
            c -= 6
        if c > ord('9'):
            c -= 7
        c -= ord('.')
        for j in range(6):
            if (c >> j) & 1:
                e[6 * i + j], e[6 * i + j + 24] = e[6 * i + j + 24], e[6 * i + j]
    return e


def subkeys():
    """For each round, the positions (1-based) in C|D (after PC1) of K's 48 bits."""
    pos = list(range(1, 57))
    ks = []
    for s in SHIFTS:
        c, d = pos[:28], pos[28:]
        c, d = c[s:] + c[:s], d[s:] + d[:s]
        pos = c + d
        ks.append([pos[p - 1] for p in PC2])
    return ks


KS = subkeys()


def perm(bits, table):
    return [bits[t - 1] for t in table]


def sbox(n, six):
    row = six[0] * 2 + six[5]
    col = six[1] * 8 + six[2] * 4 + six[3] * 2 + six[4]
    v = S[n][row * 16 + col]
    return [(v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1]


def des16(lr, cd, e):
    """Sixteen rounds in IP's domain: L|R in, R16|L16 out (next encrypt's IP(FP(.)))."""
    l, r = lr[:32], lr[32:]
    for k in KS:
        x = [a ^ cd[p - 1] for a, p in zip(perm(r, e), k)]
        f = []
        for n in range(8):
            f += sbox(n, x[6 * n:6 * n + 6])
        l, r = r, [a ^ b for a, b in zip(l, perm(f, P))]
    return r + l


def key_block(pw):
    block = [0] * 64
    i = 0
    for ch in pw[:8]:
        c = ord(ch)
        for j in range(7):
            block[i] = (c >> (6 - j)) & 1
            i += 1
        i += 1
    return block


def crypt_bits(pw, salt=SALT, iters=ITER):
    """The 64 bits after the last encrypt (FP's output), bit 1 first."""
    cd = perm(key_block(pw), PC1)
    e = salt_e(salt)
    lr = [0] * 64
    for _ in range(iters):
        lr = des16(lr, cd, e)
    return perm(lr, FP)


def bits_to_str(b, salt=SALT):
    b = b + [0, 0]
    s = salt
    for i in range(11):
        v = 0
        for j in range(6):
            v = v * 2 + b[6 * i + j]
        s += ALPHA[v]
    return s


def crypt(pw, salt=SALT, iters=ITER):
    return bits_to_str(crypt_bits(pw, salt, iters), salt)


def bits_to_int(b):
    v = 0
    for x in b:
        v = v * 2 + x
    return v


def str_to_int(h):
    """The 64-bit block (bit 1 the MSB) from a 13-character hash."""
    v = 0
    for ch in h[2:]:
        v = v * 64 + ALPHA.index(ch)
    return v >> 2


def password(n):
    """The engine's n-th password: eight characters from the 48 bits of n ^ MIX."""
    v = n ^ 0x5A5AC3C3A5A5
    return "".join(ALPHA[(v >> (6 * i)) & 63] for i in range(8))


def libcrypt():
    lib = ctypes.CDLL("libcrypt.so.1")
    lib.crypt.restype = ctypes.c_char_p
    lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    return lambda pw, salt=SALT: lib.crypt(pw.encode(), salt.encode()).decode()


# ---- SystemVerilog: bit k of DES (1-based, k=1 first) is bit [k] of a [1:N] vector
def sv_perm(name, nin, table):
    nout = len(table)
    body = ", ".join("x[%d]" % t for t in table)
    return ("function automatic logic [1:%d] %s(input logic [1:%d] x);\n"
            "    return {%s};\nendfunction\n" % (nout, name, nin, body))


def sv(salt=SALT):
    e = salt_e(salt)
    out = ["// Generated by gen_crypt.py: DES as UNIX V7 crypt(3) uses it, salt \"%s\".\n"
           "// Bit k of DES (1 first) is bit [k] of a [1:N] vector.\n" % salt]
    out.append(sv_perm("des_ip", 64, IP))
    out.append(sv_perm("des_fp", 64, FP))
    out.append(sv_perm("des_pc1", 64, PC1))
    out.append(sv_perm("des_e", 32, e))
    out.append(sv_perm("des_p", 32, P))
    for r, k in enumerate(KS):
        out.append(sv_perm("des_k%d" % (r + 1), 56, k))
    for n in range(8):
        out.append("function automatic logic [1:4] des_s%d(input logic [1:6] x);\n"
                   "    case ({x[1], x[6], x[2], x[3], x[4], x[5]})\n" % (n + 1))
        for row in range(4):
            for col in range(16):
                out.append("        6'd%d: return 4'd%d;\n" % (row * 16 + col, S[n][row * 16 + col]))
        out.append("        default: return 4'd0;\n    endcase\nendfunction\n")
    out.append("function automatic logic [1:32] des_f(input logic [1:32] r, input logic [1:48] k);\n"
               "    logic [1:48] x;\n    x = des_e(r) ^ k;\n"
               "    return des_p({")
    out.append(", ".join("des_s%d(x[%d:%d])" % (n + 1, 6 * n + 1, 6 * n + 6) for n in range(8)))
    out.append("});\nendfunction\n")
    out.append("// sixteen rounds in IP's domain: L|R in, R16|L16 out\n"
               "function automatic logic [1:64] des16(input logic [1:64] lr, input logic [1:56] cd);\n"
               "    logic [1:32] l, r, t;\n    l = lr[1:32];\n    r = lr[33:64];\n")
    for r in range(16):
        out.append("    t = l ^ des_f(r, des_k%d(cd)); l = r; r = t;\n" % (r + 1))
    out.append("    return {r, l};\nendfunction\n")
    return "".join(out)


def expect_sum(n):
    lc = libcrypt()
    s = 0
    for i in range(n):
        s = (s + str_to_int(lc(password(i)))) & ((1 << 64) - 1)
    return s


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "svh":
        # an optional salt bakes its E swaps in; ".." (the default here when a third arg
        # is given as "base") leaves E unsalted, for a design that salts at run time.
        salt = sys.argv[3] if len(sys.argv) > 3 else SALT
        if salt == "base":
            salt = ".."
        with open(sys.argv[2], "w") as f:
            f.write(sv(salt))
    elif cmd == "check":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
        lc = libcrypt()
        assert crypt("password", "ab") == "abJnggxhB/yWI", crypt("password", "ab")
        for i in range(n):
            pw = password(i * 7919)
            for salt in (SALT, "./", "zZ", "q9"):
                a, b = crypt(pw, salt), lc(pw, salt)
                assert a == b, (pw, salt, a, b)
                assert str_to_int(a) == bits_to_int(crypt_bits(pw, salt))
        print("model == libcrypt for %d passwords x 4 salts" % n)
        for i in range(3):
            print(i, password(i), crypt(password(i)))
    elif cmd == "expect":
        n = int(sys.argv[3]) if len(sys.argv) > 3 else NHASH
        s = expect_sum(n)
        lc = libcrypt()
        with open(sys.argv[2], "w") as f:
            f.write("// Generated by gen_crypt.py expect: libcrypt's hashes of the engine's passwords.\n")
            f.write("localparam int unsigned NHASH = %d;\n" % n)
            f.write("localparam logic [63:0] PW0 = \"%s\";\n" % password(0))
            f.write("localparam logic [15:0] SALT = \"%s\";\n" % SALT)
            f.write("localparam logic [63:0] EXPECT_SUM = 64'h%016x;\n" % s)
            f.write("// crypt(\"%s\", \"%s\") = %s\n" % (password(0), SALT, lc(password(0))))
            f.write("localparam logic [63:0] EXPECT_FIRST = 64'h%016x;\n" % str_to_int(lc(password(0))))
        print("n=%d sum=%016x first %s %s" % (n, s, password(0), lc(password(0))))
    elif cmd == "crack":
        out, pw = sys.argv[2], sys.argv[3]
        pwlen = int(sys.argv[4]) if len(sys.argv) > 4 else len(pw)
        assert pw and all("a" <= c <= "z" for c in pw), "monocase lowercase only: %r" % pw
        assert len(pw) == pwlen, "pw must be exactly the search length %d" % pwlen
        lc = libcrypt()
        h = lc(pw)
        assert crypt(pw) == h, (crypt(pw), h)
        with open(out, "w") as f:
            f.write("// Generated by gen_crypt.py crack: a hashed line to run the search against.\n")
            f.write("// crypt(\"%s\", \"%s\") = %s ; the demo recovers \"%s\".\n" % (pw, SALT, h, pw))
            f.write("localparam int PWLEN = %d;\n" % pwlen)
            f.write("localparam logic [15:0] SALT = \"%s\";\n" % SALT)
            f.write("localparam logic [63:0] TARGET = 64'h%016x;\n" % str_to_int(h))
            f.write("localparam logic [8*13-1:0] HASHSTR = \"%s\";\n" % h)
            f.write("localparam logic [8*%d-1:0] PWSTR = \"%s\";\n" % (pwlen, pw))
        print("crack %s: %s  target %016x  space 26^%d=%d" % (pw, h, str_to_int(h), pwlen, 26 ** pwlen))
    elif cmd == "c2vec":
        # a test vector for the crack2 engine / harness: crypt(pw, salt), as the engine sees it
        out, pw, salt = sys.argv[2], sys.argv[3], sys.argv[4]
        assert pw and all(32 <= ord(c) < 127 for c in pw), "printable ASCII only: %r" % pw
        lc = libcrypt()
        h = lc(pw, salt)
        assert crypt(pw, salt) == h, (crypt(pw, salt), h)
        sb = ALPHA.index(salt[1]) << 6 | ALPHA.index(salt[0])
        with open(out, "w") as f:
            f.write("// crypt(\"%s\", \"%s\") = %s\n" % (pw, salt, h))
            f.write("localparam logic [63:0] C2_TARGET = 64'h%016x;\n" % str_to_int(h))
            f.write("localparam logic [11:0] C2_SALT = 12'h%03x;\n" % sb)
            f.write("localparam int C2_PWLEN = %d;\n" % len(pw))
            f.write("localparam logic [8*%d-1:0] C2_PW = \"%s\";\n" % (len(pw), pw))
            f.write("localparam logic [8*13-1:0] C2_LINE = \"%s\";\n" % h)
        print("c2vec %s/%s: %s  target %016x  sb %03x" % (pw, salt, h, str_to_int(h), sb))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
