#!/usr/bin/env python3
"""pin_cells.py merged.json cell=bel ...: give cells BEL attributes (the test MMCM on a right-column CMT, the ICAPE2 on the top ICAP site)."""
import json, sys
p = sys.argv[1]; j = json.load(open(p))
m = max(j["modules"].values(), key=lambda v: len(v["cells"]))
for arg in sys.argv[2:]:
    cell, bel = arg.split("=", 1)
    m["cells"][cell]["attributes"]["BEL"] = bel; print("%s pinned to %s" % (cell, bel))
json.dump(j, open(p, "w"), indent=1)
