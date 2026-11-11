#!/usr/bin/env python3
"""console.py <log> <bit> <mmcm args|-> <seconds> [port]: load the bit, catch the BIOS, retime it, then log the
network boot to a Linux shell prompt.  Host side of a board boot."""
import subprocess, sys, time, serial, os
log, bit, mm, secs = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
s = serial.Serial(sys.argv[5] if len(sys.argv) > 5 else "/dev/ttyUSB0", 115200, timeout=0.1)
f = open(log, "wb"); all_ = bytearray()
def pump(t, stop=None, poke=None):
    t0 = time.time()
    while time.time() - t0 < t:
        if poke: s.write(poke); s.flush()
        c = s.read(4096)
        if c:
            f.write(c); f.flush(); all_.extend(c)
            if stop and stop in all_[-400:]: return True
    return False
subprocess.run(["flock", os.path.expanduser("~/synthgui/runs/2026-11-05-silicon/jtag.lock"), os.path.expanduser("~/synthgui/build-deps/prefix/bin/openFPGALoader"), "--cable", "digilent", "--freq", "15000000", bit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
if mm != "-":
    if not pump(60, b"> ", b"\x1b"): print("no BIOS prompt"); sys.exit(1)
    all_.clear(); s.write(b"\r\nmmcm " + mm.encode() + b"\r\n"); s.flush(); print("sent mmcm", mm)
ok = pump(secs, b"login: ")
print("login prompt" if ok else "no login prompt within %.0f s" % secs)
