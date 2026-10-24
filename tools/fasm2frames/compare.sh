#!/bin/bash
# compare.sh PART FAMILY FASM -- run prjxray's Python fasm2frames (via xc7/fasm2frames_fast.py) and the C++ one on the
# same FASM and compare the frames files byte for byte. Uses build-deps/venv and deps/prjxray-db from the checkout.
#   SYNTHGUI=path/to/synthgui   (default build/synthgui; its --tool fasm2frames is what is checked)
set -u
cd "$(dirname "$0")/../.."
part=$1 family=$2 fasm=$3
cpp=${SYNTHGUI:-build/synthgui}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
db=deps/prjxray-db/$family
t0=$(date +%s.%N)
PYTHONPATH=deps/prjxray build-deps/venv/bin/python xc7/fasm2frames_fast.py --part "$part" --db-root "$db" "$fasm" "$tmp/py.frames" >"$tmp/py.log" 2>&1; pyrc=$?
t1=$(date +%s.%N)
"$cpp" --tool fasm2frames --part "$part" --db-root "$db" "$fasm" "$tmp/cpp.frames" >"$tmp/cpp.log" 2>&1; cpprc=$?
t2=$(date +%s.%N)
printf "%-52s python %6.1fs rc=%d   c++ %6.1fs rc=%d   " "$(basename "$(dirname "$fasm")")/$(basename "$fasm")" \
    "$(echo "$t1 - $t0" | bc)" $pyrc "$(echo "$t2 - $t1" | bc)" $cpprc
if [ $pyrc -ne 0 ] || [ $cpprc -ne 0 ]; then
    if [ $pyrc -ne 0 ] && [ $cpprc -ne 0 ]; then echo "both fail (as they should)"; else echo "RC DIFFERS"; tail -3 "$tmp/py.log"; tail -3 "$tmp/cpp.log"; fi
    exit 1
fi
if cmp -s "$tmp/py.frames" "$tmp/cpp.frames"; then echo IDENTICAL; else echo DIFFERENT; cmp "$tmp/py.frames" "$tmp/cpp.frames" | head -2; exit 1; fi
