#!/usr/bin/env python3
"""board.py <log> <wait s> <command...>: log in on the console if needed and run shell commands, logging to a file."""
import re, sys, time, serial
log, wait = sys.argv[1], float(sys.argv[2]); cmds = sys.argv[3:]
s = serial.Serial(__import__("os").environ.get("CONSOLE", "/dev/ttyUSB0"), 115200, timeout=0.3); f = open(log, "ab")
def rd(t, stop=None):
    out = b""; t0 = time.time()
    while time.time() - t0 < t:
        c = s.read(4096)
        if c:
            out += c; f.write(c); f.flush()
            if stop and re.search(rb"CMDDONE=\d", out): break
    return out
s.write(b"\r\n"); o = rd(3)
if b"login:" in o:
    s.write(b"root\r\n"); o = rd(4)
    if b"assword" in o: print("needs a password"); sys.exit(1)
for c in cmds:
    s.write(c.encode() + b"; echo CMDDONE=$?\r\n"); s.flush()
    o = rd(wait, b"CMDDONE=")
    print(o.decode(errors="replace").replace("\r", "")[-1500:])
