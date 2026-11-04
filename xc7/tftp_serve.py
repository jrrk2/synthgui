#!/usr/bin/env python3
"""tftp_serve.py [--port 6969] [--dir .]: a minimal read-only TFTP server (RFC 1350, octet, 512-byte
blocks, blksize option honoured) on an unprivileged port, for the BIOS `netload` command."""
import argparse, os, socket, struct, sys
p = argparse.ArgumentParser(); p.add_argument("--port", type=int, default=6969); p.add_argument("--dir", default=".")
a = p.parse_args()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", a.port))
print("tftp: serving %s on udp port %d" % (os.path.abspath(a.dir), a.port), flush=True)
while True:
    pkt, peer = s.recvfrom(2048)
    op = struct.unpack("!H", pkt[:2])[0]
    if op != 1:
        s.sendto(struct.pack("!HH", 5, 4) + b"read only\0", peer); continue
    parts = pkt[2:].split(b"\0")
    name = parts[0].decode(errors="replace"); opts = parts[2:-1]
    blksize = 512
    oack = b""
    for i in range(0, len(opts) - 1, 2):
        if opts[i].lower() == b"blksize":
            blksize = max(8, min(int(opts[i + 1]), 1428)); oack += b"blksize\0" + str(blksize).encode() + b"\0"
    path = os.path.join(a.dir, os.path.basename(name))
    try:
        data = open(path, "rb").read()
    except OSError:
        s.sendto(struct.pack("!HH", 5, 1) + b"not found\0", peer); print("tftp: %s from %s: not found" % (name, peer[0]), flush=True); continue
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(2.0)
    print("tftp: %s (%d bytes) to %s" % (name, len(data), peer[0]), flush=True)
    if oack:
        c.sendto(struct.pack("!H", 6) + oack, peer)
        try: c.recvfrom(64)
        except socket.timeout: print("tftp: no ack of options", flush=True); continue
    block = 1; off = 0; ok = True
    while True:
        chunk = data[off:off + blksize]
        for attempt in range(5):
            c.sendto(struct.pack("!HH", 3, block & 0xFFFF) + chunk, peer)
            try:
                ack, _ = c.recvfrom(64)
                if struct.unpack("!HH", ack[:4]) == (4, block & 0xFFFF): break
            except socket.timeout: pass
        else:
            print("tftp: block %d not acknowledged" % block, flush=True); ok = False; break
        off += blksize; block += 1
        if len(chunk) < blksize: break
    print("tftp: done, %d blocks%s" % (block - 1, "" if ok else " (failed)"), flush=True)
