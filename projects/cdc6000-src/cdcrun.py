#!/usr/bin/env python3
"""cdcrun.py SOURCE [--port /dev/ttyUSB2] [--bit FILE]: run the CDC 6000 core's
program (the 1972 Pascal compiler) on the VC707 with SOURCE as its input, and
print what it writes.

The protocol is vc707_cdc_top.v's, at 921600 8N1: characters both ways are CDC
display code (line end 0, end of input 0x80); the board sends 0x85 when it is
up and waiting, a credit 0x83 for every 256 characters consumed (the host
keeps at most 1024 ahead), 0x81 + name + word for each word of a binary file,
and 0x82 + instruction count + cycles + fault when the core halts.

The program changes its memory as it runs, so it runs once per configuration:
with --bit the board is reprogrammed first, after the port is open, so the
0x85 is not missed."""
import argparse, subprocess, sys, time

import serial

# CDC display code, as the cdc6000 repository's emulator translates it
# (host/cdcio.h), so that this and cdcemu feed the compiler the same input
# and print its output alike: ASCII where there is a letter, digit or symbol
# for it, the 1972 glyphs from UTF-8, anything else a space.
FROM_ASCII = {**{chr(ord("A") + k): k + 1 for k in range(26)}, **{str(k): 27 + k for k in range(10)},
              "+": 37, "-": 38, "*": 39, "/": 40, "(": 41, ")": 42, "$": 43, "=": 44, " ": 45, ",": 46,
              ".": 47, "[": 49, "]": 50, ":": 51, "<": 58, ">": 59, ";": 63, "'": 48, "^": 56,
              "\u2227": 55, "\u2228": 54, "\u2260": 52, "\u2264": 60, "\u2265": 61, "\u2261": 48,
              "\u2191": 56, "\u2193": 57, "\u2192": 53, "\u00ac": 62}
TO_ASCII = ["?"] * 64
for _c, _k in FROM_ASCII.items():
    if _c.isascii():
        TO_ASCII[_k] = _c
TO_ASCII[0] = "~"
for _k, _c in {52: "#", 53: "@", 54: "|", 55: "&", 57: "!", 60: "{", 61: "}", 62: "~"}.items():
    TO_ASCII[_k] = _c


def encode(text):
    out = bytearray()
    for line in text.splitlines():
        out.extend(FROM_ASCII.get(c.upper(), 45) for c in line)
        out.append(0)  # line end
    out.append(0x80)   # end of input
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--port", default="/dev/ttyUSB2")
    ap.add_argument("--bit", help="reprogram the FPGA with this bitstream first")
    ap.add_argument("--loader", default="openFPGALoader")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--save", help="write each binary file here as <name>.out, one 20-digit octal word a line "
                                   "(the emulator's -d format)")
    ap.add_argument("--listing", help="write the listing to this file rather than printing it")
    a = ap.parse_args()

    data = encode(open(a.source).read())
    port = serial.Serial(a.port, 921600, timeout=0.2)
    port.reset_input_buffer()
    if a.bit:
        subprocess.run([a.loader, "--cable", "digilent", "--freq", "15000000", a.bit], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    sent, allowed, waiting = 0, 1024, False
    files, line = {}, []
    listing = open(a.listing, "w") if a.listing else sys.stdout
    deadline = time.time() + a.timeout
    pending = bytearray()

    def take(n):
        while len(pending) < n:
            more = port.read(64)
            if not more and time.time() > deadline:
                sys.exit("cdcrun: timed out inside a record")
            pending.extend(more)
        b = bytes(pending[:n])
        del pending[:n]
        return b

    while time.time() < deadline:
        if waiting and sent < min(len(data), allowed):
            n = min(len(data), allowed) - sent
            port.write(data[sent:sent + n])
            sent += n
        pending.extend(port.read(256))
        while pending:
            b = take(1)[0]
            if b < 0x40:
                if b == 0:
                    print("".join(line).rstrip(), file=listing)
                    line = []
                elif b:
                    line.append(TO_ASCII[b])
            elif b == 0x85:
                waiting = True
            elif b == 0x83:
                allowed += 256
            elif b == 0x81:
                # the name is a 60-bit word, ten display-code characters, left justified
                nv = int.from_bytes(take(8), "big")
                name = "".join(TO_ASCII[(nv >> (54 - 6 * i)) & 63] for i in range(10) if (nv >> (54 - 6 * i)) & 63)
                files.setdefault(name.lower(), []).append(int.from_bytes(take(8), "big"))
            elif b == 0x82:
                if line:
                    print("".join(line).rstrip(), file=listing)
                icount = int.from_bytes(take(8), "big")
                cycles = int.from_bytes(take(8), "big")
                fault = take(1)[0]
                for name, words in files.items():
                    print("file %s: %d words" % (name, len(words)))
                    if a.save:
                        with open("%s/%s.out" % (a.save, name), "w") as f:
                            for w in words:
                                f.write("%020o\n" % (w & ((1 << 60) - 1)))
                print("halted: %d instructions in %d cycles (%.2f per cycle), fault %d"
                      % (icount, cycles, icount / max(cycles, 1), fault))
                sys.exit(1 if fault else 0)
    sys.exit("cdcrun: no halt within %g s (%s)" % (a.timeout, "running" if waiting else "never waiting for input"))


if __name__ == "__main__":
    main()
