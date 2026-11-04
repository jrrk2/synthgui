#!/usr/bin/env python3
"""bios_catch.py [port]: press ESC on the console until the BIOS prompt appears (run right after a JTAG load)."""
import sys, time, serial
port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
s = serial.Serial(port, 115200, timeout=0.1)
buf = b""; t0 = time.time()
while time.time() - t0 < 90:
    s.write(b"\x1b"); s.flush()
    buf += s.read(512)
    if b"litex\x1b[0m> " in buf[-200:] or b"litex> " in buf[-200:]:
        print("BIOS prompt caught after %.1f s" % (time.time() - t0)); sys.exit(0)
sys.exit("no BIOS prompt: %r" % buf[-300:])
