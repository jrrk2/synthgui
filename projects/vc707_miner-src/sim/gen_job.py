#!/usr/bin/env python3
"""gen_job.py <outdir> -- a kHeavyHash job as mine_daemon would send it, plus
the nonce the FPGA must report, for tb_miner.sv.

Writes:
  frames.hex   every byte of every frame, one per line (hex)
  frames.len   one frame length per line (decimal), in send order
  expect.txt   "<nonce_start> <expected_nonce>" (decimal)

The frames are mine_daemon's (main.rs build_config_hdr / build_config_mat)
behind a 14-byte Ethernet header to the FPGA's MAC, without FCS: the test
bench stands in for sgmii_soc, whose MAC has already checked and stripped it.
The hashes come from ~/heavyhash/verify_pow.py, the reference the RTL was
checked against.  The target is set so that one of the first few nonces
passes: the expected nonce is the first one that does.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.expanduser("~/heavyhash"))
from verify_pow import (compute_cshake_initial_state, compute_heavy_hash,  # noqa: E402
                        generate_matrix)

FPGA_MAC = bytes.fromhex("0200004b4131")
HOST_MAC = bytes.fromhex("02000000aa01")
ETHERTYPE = b"\x4b\x41"
FT_CONFIG_HDR, FT_CONFIG_MAT = 0x01, 0x02


def state_bytes(state):
    return b"".join(struct.pack("<Q", w) for w in state)


def eth(payload):
    return FPGA_MAC + HOST_MAC + ETHERTYPE + payload


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)

    pre_pow = bytes(range(0x11, 0x11 + 32))   # any 32 bytes
    timestamp = 0x0000018F_12345678
    nonce_start = 0x0123_4567_89AB_CDE0
    window = 8

    finals = []
    for k in range(window):
        _, _, final = compute_heavy_hash(pre_pow, timestamp, nonce_start + k)
        finals.append(int.from_bytes(final, "little"))
    # target: the 4th nonce's hash; the expected nonce is the first <= it
    target = finals[3]
    expected = nonce_start + next(k for k in range(window) if finals[k] <= target)

    ms1 = state_bytes(compute_cshake_initial_state("ProofOfWorkHash"))
    ms2 = state_bytes(compute_cshake_initial_state("HeavyHash"))
    msg = bytearray(136)
    msg[0:32] = pre_pow
    msg[32:40] = struct.pack("<Q", timestamp)
    msg[80] = 0x04
    msg[135] = 0x80

    hdr = bytes([FT_CONFIG_HDR, 1]) + ms1 + ms2 + bytes(msg) \
        + target.to_bytes(32, "little") + struct.pack("<Q", nonce_start)

    matrix = generate_matrix(pre_pow)
    rows = bytearray()
    for r in range(64):
        v = 0
        for c in range(64):
            v |= matrix[r][c] << (4 * c)        # matrix.rs to_fpga_format
        rows += v.to_bytes(32, "little")
    mats = [bytes([FT_CONFIG_MAT, 2 + i, 32 * i]) + bytes(7) + bytes(rows[1024 * i:1024 * (i + 1)])
            for i in range(2)]

    frames = [eth(hdr), eth(mats[0]), eth(mats[1])]   # HDR clears the matrix flags
    with open(os.path.join(out, "frames.hex"), "w") as f:
        for fr in frames:
            f.writelines(f"{b:02x}\n" for b in fr)
    with open(os.path.join(out, "frames.len"), "w") as f:
        f.writelines(f"{len(fr)}\n" for fr in frames)
    with open(os.path.join(out, "expect.txt"), "w") as f:
        f.write(f"{nonce_start} {expected}\n")
    print(f"frames {[len(x) for x in frames]}  nonce_start {nonce_start:#x}  expected {expected:#x}"
          f" (+{expected - nonce_start})")


if __name__ == "__main__":
    main()
