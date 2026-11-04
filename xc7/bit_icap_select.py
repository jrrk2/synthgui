#!/usr/bin/env python3
"""bit_icap_select.py in.bit out.bit: set ICAP_SELECT (CTL0 bit 30, bottom ICAP = ICAP_X0Y0) in every
MASK/CTL0 write of a 7-series bitstream, so a design using the bottom ICAPE2 site is heard."""
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
sync = data.find(b"\xaa\x99\x55\x66")
if sync < 0: sys.exit("no sync word")
n = 0
i = sync + 4
while i + 8 <= len(data):
    hdr, val = struct.unpack(">II", data[i:i + 8])
    if hdr in (0x3000C001, 0x3000A001) and (val & 0x40000000) == 0:   # MASK, CTL0 type-1 writes of one word
        struct.pack_into(">I", data, i + 4, val | 0x40000000); n += 1; i += 8; continue
    if (hdr >> 29) == 1:                      # type 1: skip its payload
        i += 4 + 4 * (hdr & 0x7FF)
    elif (hdr >> 29) == 2:                    # type 2: skip its payload
        i += 4 + 4 * (hdr & 0x07FFFFFF)
    else:
        i += 4
open(sys.argv[2], "wb").write(data)
print("%s: %d MASK/CTL0 writes patched -> %s" % (sys.argv[1], n, sys.argv[2]))
