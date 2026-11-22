#!/usr/bin/env python3
"""Dictionary harness for the vc707_crack2 bitstream.

Reads words from a word list, keeps the lowercase ones of 1..MAXLEN letters, and for a
random sample of them: picks a random crypt salt (one of 4096), hashes the word with the
host's crypt(3), sends the 13-char crypt line over the serial port, reads the line the FPGA
sends back, and checks the recovered word is the one we hashed.  This shows a short monocase
password being recovered from its /etc/passwd line regardless of the salt.

  crack_harness.py [--port /dev/ttyUSB0] [--count 30] [--all] [--maxlen 6]
                   [--words /usr/share/dict/words] [--seed N]

Needs the port free (close picocom first) and pyserial (pip install pyserial).
Salt is ./0-9A-Za-z; the FPGA's DES tables are unsalted and it applies the salt at run time.
"""
import argparse
import os
import random
import re
import sys
import time

ALPHA = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

import string as _string
GLYPH_CLASSES = {
    "lower": _string.ascii_lowercase,
    "upper": _string.ascii_uppercase,
    "digits": _string.digits,
    "alpha": _string.ascii_letters,
    "alnum": _string.ascii_letters + _string.digits,
    "printable": "".join(chr(c) for c in range(33, 127)),
}


def glyph_mask_hex(spec):
    """A 128-bit ASCII mask (32 hex, MSB-first) from a class name or a literal set of chars."""
    glyphs = GLYPH_CLASSES.get(spec, spec)
    mask = 0
    for ch in glyphs:
        if 0 <= ord(ch) < 128:
            mask |= 1 << ord(ch)
    return "%032x" % mask, glyphs


def host_crypt():
    # libcrypt.so.1 (what gen_crypt.py validated against); the stdlib crypt module is gone in 3.13
    try:
        import ctypes
        lib = ctypes.CDLL("libcrypt.so.1")
        lib.crypt.restype = ctypes.c_char_p
        lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]

        def c(pw, salt):
            r = lib.crypt(pw.encode(), salt.encode())
            return r.decode() if r else ""
        if len(c("cat", "ab")) == 13:
            return c
    except Exception:
        pass
    import crypt as _c
    return lambda pw, salt: _c.crypt(pw, salt)


def crack_passwd(serial, args):
    """Feed the DES-crypt hashes from a passwd file to the board, report what it recovers."""
    desset = set(ALPHA)
    entries = []
    with open(args.passwd, encoding="latin-1") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("#") or ":" not in ln:
                continue
            parts = ln.split(":")
            user, h = parts[0], parts[1]
            if h in ("", "*", "!", "!!", "x") or h.startswith("!"):
                kind = "no/locked password"
            elif h.startswith("$"):
                kind = "modern hash (%s), not DES" % (h.split("$")[1] if "$" in h[1:] else "?")
            elif len(h) == 13 and set(h) <= desset:
                entries.append((user, h))
                continue
            else:
                kind = "unrecognized field %r" % h
            print("  skip %-10s %s" % (user, kind))
    if not entries:
        sys.exit("no DES-crypt hashes in %s" % args.passwd)
    ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    time.sleep(0.2)
    if args.glyphs:
        mask, glyphs = glyph_mask_hex(args.glyphs)
        ser.reset_input_buffer()
        ser.write(("%" + mask + "\n").encode())
        time.sleep(0.2)
        print("alphabet set to '%s' (%d glyphs, mask %s)" % (args.glyphs, len(set(glyphs)), mask))
    print("%d DES hash(es) to crack (<=6-char sweep of the chosen alphabet):" % len(entries))
    for user, h in entries:
        ser.reset_input_buffer()
        ser.write((h + "\n").encode())
        reply = ser.readline().decode(errors="replace").strip()
        m = re.match(r"(OK|NF)\s+(\S*)\s+tries=([0-9a-f]+)\s+ms=(\d+)", reply)
        if m and m.group(1) == "OK":
            print("  %-10s %s  ->  password \"%s\"  (%d tries)"
                  % (user, h, m.group(2), int(m.group(3), 16)))
        elif m:
            print("  %-10s %s  ->  not a <=6-char %s password (swept %d)"
                  % (user, h, args.glyphs or "lowercase", int(m.group(3), 16)))
        else:
            print("  %-10s %s  ->  no/garbled reply: %r" % (user, h, reply))
    ser.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)  # 100 MHz crack2; use 19200 for the 16.67 MHz build
    ap.add_argument("--words", default="/usr/share/dict/words")
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--maxlen", type=int, default=6)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--passwd", help="crack the DES hashes in a passwd/master.passwd file instead")
    ap.add_argument("--glyphs", help="alphabet to sweep: a class (lower/upper/digits/alpha/alnum/"
                    "printable) or a literal set of characters; sent to the board before cracking")
    args = ap.parse_args()

    import serial  # pyserial

    if args.passwd:
        crack_passwd(serial, args)
        return

    crypt = host_crypt()
    pat = re.compile("^[a-z]{1,%d}$" % args.maxlen)
    paths = [args.words, "/usr/share/dict/words", "/usr/share/dict/american-english",
             "/usr/share/dict/british-english", "/usr/dict/words"]
    wf = next((p for p in paths if os.path.exists(p)), None)
    if wf is None:
        sys.exit("no word list found (tried %s); pass --words <file>" % ", ".join(paths))
    with open(wf, encoding="latin-1") as f:
        words = sorted({w.strip() for w in f if pat.match(w.strip())})
    if not words:
        sys.exit("no 1..%d lowercase words in %s" % (args.maxlen, wf))
    args.words = wf
    random.seed(args.seed)
    sample = words if args.all else random.sample(words, min(args.count, len(words)))
    sample.sort(key=lambda w: (len(w), w))  # shortest first: quick wins, slow 6-letter ones last
    print("%d candidate words in %s; cracking %d (shortest first; 6-letter words are the slow "
          "ones, ~15 s each at 100 MHz)" % (len(words), args.words, len(sample)))

    ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    time.sleep(0.2)

    ok = bad = 0
    t0 = time.time()
    for i, word in enumerate(sample, 1):
        salt = random.choice(ALPHA) + random.choice(ALPHA)
        line = crypt(word, salt)                      # 13 chars: salt + 11 hash
        ser.reset_input_buffer()                      # drop any stale late reply, stay in sync
        ser.write((line + "\n").encode())
        reply = ser.readline().decode(errors="replace").strip()
        m = re.match(r"(OK|NF)\s+(\S*)\s+tries=([0-9a-f]+)\s+ms=(\d+)", reply)
        if m and m.group(1) == "OK" and m.group(2) == word:
            ok += 1
            verdict = "ok"
        else:
            bad += 1
            verdict = "MISMATCH"
        tries = int(m.group(3), 16) if m else -1
        ms = int(m.group(4)) if m else -1
        print("%4d  %-8s salt %-2s  %s  -> %-10s %10d tries  %6d ms  [%s]"
              % (i, word, salt, line, m.group(2) if m else "(%s)" % reply, tries, ms, verdict))
    dt = time.time() - t0
    print("\n%d recovered, %d mismatched, in %.1f s" % (ok, bad, dt))
    ser.close()
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
