#!/bin/bash
# compare.sh NETLIST.json TILEGRID.json DELAYMATRIX|formula NAME=placement [more bram_fom options...]
# -- run deps/nextpnr/.github/scripts/bram_fom.py and `synthgui --tool bram-fom` with the same arguments and compare
# their output and exit status.   SYNTHGUI=path (default build/synthgui)
set -u
cd "$(dirname "$0")/../.."
bin=${SYNTHGUI:-build/synthgui}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
args=(--netlist "$1" --tilegrid "$2" --delay-matrix "$3"); shift 3
t0=$(date +%s.%N)
python3 deps/nextpnr/.github/scripts/bram_fom.py "${args[@]}" "$@" >"$tmp/py.out" 2>"$tmp/py.err"; prc=$?
t1=$(date +%s.%N)
"$bin" --tool bram-fom "${args[@]}" "$@" >"$tmp/cpp.out" 2>"$tmp/cpp.err"; crc=$?
t2=$(date +%s.%N)
printf "python %5.1fs rc=%d   c++ %5.1fs rc=%d   " "$(echo "$t1 - $t0" | bc)" $prc "$(echo "$t2 - $t1" | bc)" $crc
if [ $prc -eq $crc ] && cmp -s "$tmp/py.out" "$tmp/cpp.out"; then echo "IDENTICAL ($(wc -l < "$tmp/py.out" | tr -d ' ') lines)"; else echo DIFFERENT; diff "$tmp/py.out" "$tmp/cpp.out" | head -6; tail -2 "$tmp/py.err" "$tmp/cpp.err"; exit 1; fi
