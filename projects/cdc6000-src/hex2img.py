#!/usr/bin/env python3
"""hex2img.py MEM_HEX IMG: a $readmemh file (mkmem.py's) as cdcemu's image, one octal 'address word' a line."""
import sys

a = 0
with open(sys.argv[2], "w") as out:
    for line in open(sys.argv[1]):
        line = line.strip()
        if line.startswith("@"):
            a = int(line[1:], 16)
        elif line:
            out.write("%o %o\n" % (a, int(line, 16)))
            a += 1
