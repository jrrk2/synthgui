#!/usr/bin/env python3
"""selfhost_check.py MEM_HEX BOARD_DIR EMU_DIR RUNTIME_IMG PARMLIST NEXT_IMG [OCTAL_WORD ...]

The checks after the board has compiled the compiler (make selfhost):

 1. the board's binary files (pasclgo.out, pmdfile.out) are the emulator's,
    bit for bit, for the same memory image;
 2. the compiler built from the board's pasclgo.out (pasclgo2img.py, with
    PARMLIST: the compile's parameter list, which the board cannot read back
    from its memory) is word for word the compiler the board ran -- the
    self-hosting fixed point.

Exit 0 when both hold.

The optional OCTAL_WORDs are addresses where the two compilers differ on purpose, and are left out of the comparison:
the Sonata build has the stack limit (word 3) lowered to fit its 32K words of memory, which the compiler built from
the board's output sets back to the default."""
import sys


def load_img(path):
    m = {}
    for line in open(path):
        if line.strip():
            a, w = line.split()
            m[int(a, 8)] = int(w, 8)
    return m


def load_hex(path):
    m, a = {}, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line.startswith("@"):
            a = int(line[1:], 16)
            continue
        m[a] = int(line, 16)
        a += 1
    return m


def main():
    mem_hex, board, emu, runtime, parmlist, next_img = sys.argv[1:7]
    skip = {int(a, 8) for a in sys.argv[7:]}
    ok = True
    for f in ("pasclgo.out", "pmdfile.out"):
        same = open("%s/%s" % (board, f)).read() == open("%s/%s" % (emu, f)).read()
        words = sum(1 for _ in open("%s/%s" % (board, f)))
        print("%-12s %5d words  board %s emulator" % (f, words, "==" if same else "!="))
        ok &= same
    rt = load_img(runtime)
    ran = {a: w for a, w in load_hex(mem_hex).items() if a not in rt}
    built = load_img(next_img)
    diff = [a for a in set(ran) | set(built) if a not in skip and ran.get(a) != built.get(a)]
    print("compiler built from the board's output: %d words, %d differing from the compiler the board ran"
          % (len(built), len(diff)))
    ok &= not diff
    print("SELF-HOSTING FIXED POINT ON THE BOARD" if ok else "NOT a fixed point")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
