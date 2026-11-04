#!/usr/bin/env python3
"""sfl_upload.py <image> [port] [address]: type `sload` at the BIOS prompt and
send the image with the serial flash loader protocol (litex_term's frames),
stop-and-wait, leaving it in memory for `icap <address> <nwords>`."""
import sys, time, serial
# LiteX on the path (its venv, or PYTHONPATH), for the SFL frame format
from litex.tools.litex_term import SFLFrame, sfl_magic_req, sfl_magic_ack, sfl_cmd_load, sfl_cmd_jump, sfl_ack_success

img = open(sys.argv[1], "rb").read()
port = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"
addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x41000000
s = serial.Serial(port, 115200, timeout=0.02)
s.write(b"\r\nsload\r\n"); s.flush()
buf = b""
t0 = time.time()
while sfl_magic_req not in buf:
    buf += s.read(1)
    if time.time() - t0 > 20:
        sys.exit("no SFL magic from the BIOS (got %r)" % buf[-200:])
s.write(sfl_magic_ack); s.flush()
s.timeout = 2
chunk = 251
n = 0
noise = []
t0 = time.time()
for off in range(0, len(img), chunk):
    f = SFLFrame()
    f.cmd = sfl_cmd_load
    f.payload = (addr + off).to_bytes(4, "big") + img[off:off + chunk]
    for attempt in range(5):
        s.write(f.encode()); s.flush()
        r = b""
        while True:
            c = s.read(1)
            if c == b"" or c in (b"K", b"C", b"U", b"E"):
                r += c
                break
            noise.append(c)
        if r == sfl_ack_success:
            break
    else:
        sys.exit("frame at offset %d not acknowledged (last reply %r, noise %r)" % (off, r, b"".join(noise)[-120:]))
    n += 1
f = SFLFrame(); f.cmd = sfl_cmd_jump; f.payload = addr.to_bytes(4, "big")
s.write(f.encode()); s.flush()
tail = s.read(300)
if noise: print("noise from the BIOS: %r" % b"".join(noise)[-200:])
print("%d bytes in %d frames to 0x%08x in %.1f s; BIOS says: %r" % (len(img), n, addr, time.time() - t0, tail))
print("now: icap 0x%08x %d" % (addr, len(img) // 4))
