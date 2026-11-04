#!/usr/bin/env python3
"""bit_packets.py file.bit: list the configuration register writes of a 7-series bitstream (header, between
frame data blocks, trailer), decoding CMD values; FDRI payloads are summarised."""
import struct, sys
REG = {0:"CRC",1:"FAR",2:"FDRI",3:"FDRO",4:"CMD",5:"CTL0",6:"MASK",7:"STAT",8:"LOUT",9:"COR0",10:"MFWR",11:"CBC",12:"IDCODE",13:"AXSS",14:"COR1",16:"WBSTAR",17:"TIMER",19:"UNKNOWN19",22:"BOOTSTS",24:"CTL1",31:"BSPI"}
CMD = {0:"NULL",1:"WCFG",2:"MFW",3:"LFRM",4:"RCFG",5:"START",6:"RCAP",7:"RCRC",8:"AGHIGH",9:"SWITCH",10:"GRESTORE",11:"SHUTDOWN",12:"GCAPTURE",13:"DESYNC",15:"IPROG",16:"CRCC",17:"LTIMER"}
d = open(sys.argv[1], "rb").read()
i = d.find(b"\xaa\x99\x55\x66")
if i < 0: sys.exit("no sync")
i += 4; reg = None; nops = 0
while i + 4 <= len(d):
    w = struct.unpack(">I", d[i:i+4])[0]; i += 4
    t = w >> 29; op = (w >> 27) & 3
    if t == 1:
        reg = (w >> 13) & 0x3FFF; n = w & 0x7FF
        if op == 0: nops += 1; continue
        if nops: print("  (%d NOP)" % nops); nops = 0
        vals = [struct.unpack(">I", d[i+4*k:i+4+4*k])[0] for k in range(n)]; i += 4 * n
        name = REG.get(reg, "reg%d" % reg)
        if name == "CMD" and vals: print("%s %s" % (name, CMD.get(vals[0], hex(vals[0]))))
        elif name == "FDRI": print("FDRI %d words" % n)
        else: print("%s %s" % (name, " ".join("0x%08x" % v for v in vals)))
    elif t == 2:
        n = w & 0x7FFFFFF
        print("%s (type2) %d words = %.1f frames" % (REG.get(reg, "?"), n, n / 101.0)); i += 4 * n
    else:
        print("word 0x%08x" % w)
