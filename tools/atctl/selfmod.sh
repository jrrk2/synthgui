#!/bin/sh
# selfmod.sh <name>: window-<name>.json -> route -> frames -> image -> ICAP, native code only, all on this board
n=$1; t() { echo "$(cut -d' ' -f1 /proc/uptime) $1"; }
t start
./nextpnr-himbaechel --device xc7vx485tffg1761-2 --chipdb chipdb-win.bin --json window-$n.json -o xdc=window.xdc --router router2 --timing-allow-fail -o hold-fix -o clock-tree=off -o delay-matrix=off -o pr-reserve=reserve-$n.txt --threads 1 --seed 1 -o fasm=$n.fasm > $n.log 2>&1 || { echo route failed; exit 1; }
t routed
grep -v '^#' $n.fasm > /tmp/$n.fasm
./fasm2frames --part xc7vx485tffg1761-2 --db-root minidb /tmp/$n.fasm /tmp/$n.frames || exit 1
t frames
read h r f < row.txt
./pr_image /tmp/$n.frames $h $r $f $n.icap || exit 1
t image
./atctl icap $n.icap || exit 1
t loaded
