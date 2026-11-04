#!/usr/bin/env python3
"""Decode `atread` output of an at_gen.py block: its 16-bit per-path counters
are LFSRs (x^16+x^14+x^13+x^11, reset state 1), so a printed value is a
state, not a count.  usage: at_decode.py <hex or decimal values...>"""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from at_gen import lfsr16_decode
table = lfsr16_decode()
for v in sys.argv[1:]:
    s = int(v, 0) & 0xFFFF
    print("%s -> %s" % (v, table.get(s, "not a reachable state (0 = never reset?)")))
