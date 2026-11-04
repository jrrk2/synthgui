#!/usr/bin/env python3
"""bios_cmd.py [--port P] [--wait S] <cmd> ...: type BIOS commands over the console, print the replies."""
import sys, time, serial
args = sys.argv[1:]
port = "/dev/ttyUSB0"; wait = 3.0
while args and args[0].startswith("--"):
    if args[0] == "--port": port = args[1]
    if args[0] == "--wait": wait = float(args[1])
    args = args[2:]
s = serial.Serial(port, 115200, timeout=0.2)
for cmd in args:
    s.write(cmd.encode() + b"\r\n"); s.flush()
    out = b""; t0 = time.time(); quiet = 0
    while time.time() - t0 < wait:
        c = s.read(256)
        if c: out += c; quiet = 0
        else:
            quiet += 1
            if quiet > 3 and b"litex" in out[-40:]: break
    print(out.decode(errors="replace").replace("\x1b[92;1m", "").replace("\x1b[0m", "").strip())
