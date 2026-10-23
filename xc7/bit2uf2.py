#!/usr/bin/env python3
"""Wrap a bitstream in UF2 blocks for the lowRISC Sonata board's SONATA drive.

    bit2uf2.py in.bit out.bit.slot1.uf2 [--slot 1|2|3]

Same as sonata-system's  uf2conv -b <slot base> -f 0x6ce29e6b in.bit -co out.uf2
(slot bases 0x00000000, 0x10000000, 0x20000000).  The slot is also picked by the
bitstream switch on the board.
"""
import argparse
import struct

FAMILY = 0x6CE29E6B
SLOT_BASE = {1: 0x00000000, 2: 0x10000000, 3: 0x20000000}
PAYLOAD = 256

a = argparse.ArgumentParser()
a.add_argument("bit")
a.add_argument("uf2")
a.add_argument("--slot", type=int, choices=SLOT_BASE, default=1)
a = a.parse_args()

data = open(a.bit, "rb").read()
n = (len(data) + PAYLOAD - 1) // PAYLOAD
out = bytearray()
for i in range(n):
    chunk = data[i * PAYLOAD:(i + 1) * PAYLOAD].ljust(476, b"\0")
    out += struct.pack("<8I", 0x0A324655, 0x9E5D5157, 0x2000,
                       SLOT_BASE[a.slot] + i * PAYLOAD, PAYLOAD, i, n, FAMILY)
    out += chunk + struct.pack("<I", 0x0AB16F30)
open(a.uf2, "wb").write(out)
print(f"{a.uf2}: {n} blocks, slot {a.slot}")
