#!/usr/bin/env python3
"""hw_probe.py <iface> [jobdir] -- the tb_miner test on the board, over Ethernet.

Sends gen_job.py's job (CONFIG_HDR, CONFIG_MAT x2: what mine_daemon sends) to
the FPGA's MAC from <iface>, waiting for each ACK as mine_daemon does, then
listens for NONCE_FOUND and HEARTBEAT frames.  Passes when all three frames
are ACKed and the reported nonce is the one verify_pow.py predicts.

Needs a raw socket (root or CAP_NET_RAW):  sudo python3 -I hw_probe.py eno1
jobdir defaults to a fresh gen_job.py run in /tmp/vc707_miner_job.
"""
import os
import socket
import struct
import subprocess
import sys
import time

ETH_P = 0x4B41
FPGA_MAC = bytes.fromhex("0200004b4131")
NAMES = {1: "CONFIG_HDR", 2: "CONFIG_MAT", 3: "NONCE_FOUND", 4: "HEARTBEAT", 5: "NAK", 6: "ACK"}


def load_job(d):
    data = bytes(int(l, 16) for l in open(os.path.join(d, "frames.hex")) if l.strip())
    lens = [int(l) for l in open(os.path.join(d, "frames.len")) if l.strip()]
    frames, o = [], 0
    for n in lens:
        frames.append(data[o:o + n])
        o += n
    start, expect = map(int, open(os.path.join(d, "expect.txt")).read().split())
    return frames, start, expect


def describe(f):
    t = f[14]
    s = f"{NAMES.get(t, hex(t))} seq={f[15]} from {f[6:12].hex(':')}"
    if t == 3:
        s += f" nonce={struct.unpack_from('<Q', f, 16)[0]:#018x}"
    if t == 4:
        hc, st, up = struct.unpack_from("<QBI", f, 16)
        s += f" hash_count={hc} status={st:#04x} uptime={up}s"
    return s


def main():
    iface = sys.argv[1]
    jobdir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/vc707_miner_job"
    if len(sys.argv) <= 2:
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.run([sys.executable, "-I", os.path.join(here, "gen_job.py"), jobdir], check=True)
    frames, start, expect = load_job(jobdir)

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P))
    s.bind((iface, 0))
    my_mac = s.getsockname()[4]
    # the FPGA answers whoever sent the frame: use this interface's MAC
    frames = [FPGA_MAC + my_mac + f[12:] for f in frames]
    print(f"{iface} {my_mac.hex(':')} -> FPGA {FPGA_MAC.hex(':')}; expect nonce {expect:#018x} (start {start:#x})")

    def recv(timeout):
        s.settimeout(timeout)
        try:
            f = s.recv(2048)
        except socket.timeout:
            return None
        return f if len(f) >= 16 and f[6:12] == FPGA_MAC else b""

    acks = 0
    for f in frames:
        seq, ok = f[15], False
        for attempt in range(3):
            s.send(f)
            end = time.time() + 1.0
            while time.time() < end:
                r = recv(end - time.time())
                if r is None:
                    break
                if r:
                    print("  rx", describe(r))
                    if r[14] == 6 and r[15] == seq:
                        ok = True
                        break
            if ok:
                break
            print(f"  no ACK for {NAMES[f[14]]} seq={seq} (attempt {attempt + 1})")
        acks += ok
        if not ok:
            break

    found = None
    hbs = 0
    end = time.time() + 3.0
    while time.time() < end and acks == len(frames):
        r = recv(end - time.time())
        if r is None:
            break
        if r:
            print("  rx", describe(r))
            if r[14] == 3:
                found = struct.unpack_from("<Q", r, 16)[0]
            if r[14] == 4:
                hbs += 1
    ok = acks == len(frames) and found == expect
    print(f"acks {acks}/{len(frames)}, nonce {found:#018x} " if found is not None else
          f"acks {acks}/{len(frames)}, no NONCE_FOUND ", end="")
    print(f"heartbeats {hbs}: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
