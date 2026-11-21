#!/bin/bash
# compare.sh FASM PLACEMENT HEXDIR [CELL_REGEX] -- run the Python update_bram_init.py (vortex hw/syn/xilinx/vc707) and
# `synthgui --tool bram-init` on the same routed FASM and lane images and compare the patched files byte for byte.
# Checks the unchanged images (output must equal the input) and a copy with three words altered.
#   SYNTHGUI=path/to/synthgui   (default build/synthgui)
#   UPDATE_PY=path/to/update_bram_init.py   (default ~/vortex/hw/syn/xilinx/vc707/update_bram_init.py)
set -u
cd "$(dirname "$0")/../.."
fasm=$1 placement=$2 hexdir=$3 cell=${4:-'g_lane_(\d+)__lane_mem_inst_t0'}
cpp=${SYNTHGUI:-build/synthgui}
py=${UPDATE_PY:-$HOME/vortex/hw/syn/xilinx/vc707/update_bram_init.py}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
run() {   # run NAME HEXDIR
    local name=$1 dir=$2
    python3 -I "$py" --placement "$placement" --fasm "$fasm" --hexdir "$dir" --out "$tmp/$name.py.fasm" >"$tmp/$name.py.log" 2>&1
    local pyrc=$?
    "$cpp" --tool bram-init --fasm "$fasm" --placement "$placement" --cell "$cell" --hexdir "$dir" --out "$tmp/$name.cpp.fasm" >"$tmp/$name.cpp.log" 2>&1
    local cpprc=$?
    printf "%-10s python rc=%d   c++ rc=%d   " "$name" $pyrc $cpprc
    if [ $pyrc -ne 0 ] || [ $cpprc -ne 0 ]; then echo "FAILED"; tail -2 "$tmp/$name.py.log" "$tmp/$name.cpp.log"; rc=1; return; fi
    if cmp -s "$tmp/$name.py.fasm" "$tmp/$name.cpp.fasm"; then echo IDENTICAL; else echo DIFFERENT; cmp "$tmp/$name.py.fasm" "$tmp/$name.cpp.fasm" | head -2; rc=1; fi
}
run unchanged "$hexdir"
if cmp -s "$fasm" "$tmp/unchanged.cpp.fasm"; then echo "unchanged images leave the FASM as it was"; else echo "unchanged images CHANGED the FASM"; rc=1; fi
mkdir -p "$tmp/mod"
cp "$hexdir"/lane*.hex "$tmp/mod/"
python3 -I - "$tmp/mod" <<'EOF'
import sys, os
d = sys.argv[1]
for lane, addr, val in ((0, 5, 0xff), (17, 1000, 0x81), (63, 4095, 0x5a)):
    p = os.path.join(d, f"lane{lane:02d}.hex")
    if not os.path.exists(p): continue
    w = open(p).read().split("\n")
    while len(w) <= addr: w.append("00")
    w[addr] = f"{val:02x}"
    open(p, "w").write("\n".join(w))
EOF
run modified "$tmp/mod"
exit $rc
