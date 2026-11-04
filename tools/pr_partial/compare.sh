#!/bin/bash
# compare.sh [INPUTS_RUN]: run the Python partial-reconfiguration tools in xc7/ and the built-ins on the same inputs and compare
# every output, and stdout, byte for byte.  Uses a harness and a window build from a run directory (default
# runs/2026-11-04-lockstep, with the at_block block of runs/2026-11-03-atspeed and the window map of runs/2026-11-04-fpu).
#   SYNTHGUI=path/to/synthgui   (default build/synthgui)
#   OUT=dir                     keep the outputs there (default a temporary directory)
set -u
cd "$(dirname "$0")/../.."
L=${1:-runs/2026-11-04-lockstep}
cpp=${SYNTHGUI:-build/synthgui}
ATBLOCK=${ATBLOCK:-runs/2026-11-03-atspeed/harness/synth-block/at_block.json}
WMAP=${WMAP:-runs/2026-11-04-fpu/win/window-map.json}
DB=${DB:-deps/prjxray-db/virtex7}; PART=${PART:-xc7vx485tffg1761-2}; TG=$DB/xc7vx485t/tilegrid.json; WIN=${WIN:-354,53,390,103}
HARNESS=$L/soc/synth/xilinx_vc707.json; BLOCK=$L/loop/new.json; IFACE=$L/soc/pnr/interface.txt
HFASM=$L/soc/pnr/harness.fasm; HFRAMES=$L/soc/pnr/harness.frames; WFASM=$L/loop/new-board/window.fasm
if [ -n "${OUT:-}" ]; then tmp=$OUT; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
bad=0
# check NAME PY_OUTPUT CPP_OUTPUT: the outputs compared with cmp, whole files
same() {
    if cmp -s "$1" "$2"; then return 0; fi
    echo "  DIFFERENT $1 $2: $(cmp "$1" "$2" 2>&1 | head -1)"; return 1
}
# run NAME "PYTHON ARGS" "TOOL ARGS" FILE...: each FILE is a relative path that both runs write, in py/ and cpp/ below $tmp/NAME
run() {
    local name=$1 pyargs=$2 tool=$3 toolargs=$4; shift 4
    local d=$tmp/$name; mkdir -p "$d/py" "$d/cpp"
    local t0 t1 t2 pyrc cpprc ok=1
    t0=$(date +%s.%N)
    ( eval "python3 $pyargs" ) >"$d/py.log" 2>&1; pyrc=$?
    t1=$(date +%s.%N)
    ( eval "\"$cpp\" --tool $tool $toolargs" ) >"$d/cpp.log" 2>&1; cpprc=$?
    t2=$(date +%s.%N)
    printf "%-22s python %6.1fs rc=%d   c++ %6.1fs rc=%d   " "$name" "$(echo "$t1 - $t0" | bc)" $pyrc "$(echo "$t2 - $t1" | bc)" $cpprc
    if [ $pyrc -ne 0 ] || [ $cpprc -ne 0 ]; then
        if [ $pyrc -ne 0 ] && [ $cpprc -ne 0 ]; then echo "both fail (as they should)"; else echo "RC DIFFERS"; tail -3 "$d/py.log"; tail -3 "$d/cpp.log"; bad=1; fi
        return
    fi
    # the logs name the output directory, the one thing that may differ
    sed "s#$d/py#OUT#g" "$d/py.log" >"$d/py.txt"; sed "s#$d/cpp#OUT#g" "$d/cpp.log" >"$d/cpp.txt"
    same "$d/py.txt" "$d/cpp.txt" || ok=0
    for f in "$@"; do same "$d/py/$f" "$d/cpp/$f" || ok=0; done
    if [ $ok = 1 ]; then echo IDENTICAL; else echo DIFFERENT; bad=1; fi
}

for prefix in at_block. at_block; do
    run "merge-$prefix" "xc7/pr_block_json.py merge --harness $HARNESS --block $ATBLOCK --instance at_block --prefix $prefix --out \$d/py/m.json" \
        pr-block-json "merge --harness $HARNESS --block $ATBLOCK --instance at_block --prefix $prefix --out \$d/cpp/m.json" m.json
done
run window "xc7/pr_block_json.py window --block $BLOCK --harness $HARNESS --instance at_block --interface $IFACE --map $WMAP --prefix at_block. --out \$d/py/window.json --reserve \$d/py/reserve.txt" \
    pr-block-json "window --block $BLOCK --harness $HARNESS --instance at_block --interface $IFACE --map $WMAP --prefix at_block. --out \$d/cpp/window.json --reserve \$d/cpp/reserve.txt" window.json reserve.txt
run window-noinst "xc7/pr_block_json.py window --block $BLOCK --harness $HARNESS --instance no_such_cell --interface $IFACE --map $WMAP --prefix x --out \$d/py/w.json" \
    pr-block-json "window --block $BLOCK --harness $HARNESS --instance no_such_cell --interface $IFACE --map $WMAP --prefix x --out \$d/cpp/w.json"

# two real cells of the merged netlist, pinned in copies of it
pin=$tmp/merge-at_block./py/m.json
if [ -f "$pin" ]; then
    cells=$(grep -o '^    "at_block\.[^"]*": {' "$pin" | sed 's/^ *"//; s/": {$//' | head -2)
    mkdir -p "$tmp/pin-cells/py" "$tmp/pin-cells/cpp"
    cp "$pin" "$tmp/pin-cells/py/p.json"; cp "$pin" "$tmp/pin-cells/cpp/p.json"
    set -- $cells
    run pin-cells "xc7/pin_cells.py \$d/py/p.json '$1=SLICE_X0Y0/AFF' '$2=SLICE_X1Y1/ALUT'" \
        pin-cells "\$d/cpp/p.json '$1=SLICE_X0Y0/AFF' '$2=SLICE_X1Y1/ALUT'" p.json
    run pin-cells-nocell "xc7/pin_cells.py \$d/py/absent.json a=b" pin-cells "\$d/cpp/absent.json a=b"
fi
for depths in 0,3,6,10,12 0,1,2,4,8; do
    run "at-gen-$depths" "xc7/at_gen.py --depths $depths \$d/py/o.json" at-gen "--depths $depths \$d/cpp/o.json" o.json
done
run at-decode "xc7/at_decode.py 1 2 0x8000 0xFFFF 0 65536 -1 0b101 0o17 1_000 0xdead 0x12345678901234567890" \
    at-decode "1 2 0x8000 0xFFFF 0 65536 -1 0b101 0o17 1_000 0xdead 0x12345678901234567890"

run pr-merge "xc7/pr_partial.py --tilegrid $TG --window $WIN merge $HFASM $WFASM \$d/py/merged.fasm" \
    pr-partial "--tilegrid $TG --window $WIN merge $HFASM $WFASM \$d/cpp/merged.fasm" merged.fasm
merged=$tmp/pr-merge/py/merged.fasm
if [ -f "$merged" ]; then
    "$cpp" --tool fasm2frames --part "$PART" --db-root "$DB" "$merged" "$tmp/merged.frames"
    run pr-extract "xc7/pr_partial.py --tilegrid $TG --window $WIN extract $tmp/merged.frames \$d/py/w.icap --ref $HFRAMES --frames-out \$d/py/w.frames" \
        pr-partial "--tilegrid $TG --window $WIN extract $tmp/merged.frames \$d/cpp/w.icap --ref $HFRAMES --frames-out \$d/cpp/w.frames" w.icap w.frames
    run pr-extract-noref "xc7/pr_partial.py --tilegrid $TG --window $WIN extract $tmp/merged.frames \$d/py/w.icap --frames-out \$d/py/w.frames" \
        pr-partial "--tilegrid $TG --window $WIN extract $tmp/merged.frames \$d/cpp/w.icap --frames-out \$d/cpp/w.frames" w.icap w.frames w.frames.type1
    run pr-extract-outside "xc7/pr_partial.py --tilegrid $TG --window 354,53,360,103 extract $tmp/merged.frames \$d/py/w.icap --ref $HFRAMES" \
        pr-partial "--tilegrid $TG --window 354,53,360,103 extract $tmp/merged.frames \$d/cpp/w.icap --ref $HFRAMES"
    # the fast path against the full one: a trimmed database, no tilegrid, one row
    p=$tmp/prep; rm -rf "$p"
    if "$cpp" --tool pr-partial --tilegrid "$TG" --window "$WIN" prep "$HFASM" "$p" --db-root "$DB" --part "$PART" >"$tmp/prep.log" 2>&1; then
        cat "$p/base.fasm" "$WFASM" >"$p/merged.fasm"
        "$cpp" --tool fasm2frames --part "$PART" --db-root "$p/minidb" "$p/merged.fasm" "$p/mini.frames" \
            && "$cpp" --tool pr-partial extract "$p/mini.frames" "$p/mini.icap" --row "$p/row.txt" >"$tmp/fast.log" 2>&1
        printf "%-22s " fast-extract
        if cmp "$p/mini.icap" "$tmp/pr-extract/py/w.icap"; then echo "IDENTICAL to the full extract"; else echo DIFFERENT; bad=1; fi
    else
        echo "prep failed:"; cat "$tmp/prep.log"; bad=1
    fi
fi
exit $bad
