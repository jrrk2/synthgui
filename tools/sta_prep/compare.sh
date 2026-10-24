#!/bin/bash
# compare.sh WORKDIR TOP -- run sta/nextpnr_sta.py and `synthgui --tool sta-prep` on WORKDIR/TOP_routed.json, TOP.sdf and
# pnr.log, and compare the four files they write and the summary line.   SYNTHGUI=path (default build/synthgui)
set -u
cd "$(dirname "$0")/../.."
w=$1 top=$2
bin=${SYNTHGUI:-build/synthgui}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
args=(--json "$w/${top}_routed.json" --sdf "$w/$top.sdf" --log "$w/pnr.log")
t0=$(date +%s.%N)
python3 sta/nextpnr_sta.py "${args[@]}" --out "$tmp/py" >"$tmp/py.out" 2>&1; prc=$?
t1=$(date +%s.%N)
"$bin" --tool sta-prep "${args[@]}" --out "$tmp/cpp" >"$tmp/cpp.out" 2>&1; crc=$?
t2=$(date +%s.%N)
printf "%-28s python %6.1fs rc=%d   c++ %6.1fs rc=%d   " "$(basename "$w")" "$(echo "$t1 - $t0" | bc)" $prc "$(echo "$t2 - $t1" | bc)" $crc
[ $prc -ne 0 ] || [ $crc -ne 0 ] && { echo "RC (see $tmp)"; trap - EXIT; tail -2 "$tmp/py.out" "$tmp/cpp.out"; exit 1; }
sed -i.bak "s#$tmp/py#OUT#" "$tmp/py.out"; sed -i.bak "s#$tmp/cpp#OUT#" "$tmp/cpp.out"
bad=0
for f in nextpnr_xc7.lib routed.v routed.sdf sta.tcl; do cmp -s "$tmp/py/$f" "$tmp/cpp/$f" || { echo -n "DIFF:$f "; bad=1; }; done
cmp -s "$tmp/py.out" "$tmp/cpp.out" || { echo -n "DIFF:summary "; bad=1; }
[ $bad -eq 0 ] && echo IDENTICAL || { echo; trap - EXIT; echo "kept $tmp"; exit 1; }
