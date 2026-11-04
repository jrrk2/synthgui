#!/bin/bash
# trace.sh <job name> <window name>: the board's nextpnr job under the plugin
T=${T:-$HOME/synthgui/runs/vexcache}; N=${N:-$HOME/vc707-nfsroot/tmp/pnr}   # T holds qbuild/ (QEMU --enable-plugins), vexcache.so, trace/
cd $N
time $T/qbuild/qemu-riscv32 -plugin $T/vexcache.so,out=$T/trace/$1.csv ./nextpnr-himbaechel --device xc7vx485tffg1761-2 --chipdb chipdb-win.bin --json window-$2.json -o xdc=window.xdc --router router2 --timing-allow-fail -o hold-fix -o clock-tree=off -o delay-matrix=off -o pr-reserve=reserve-$2.txt --threads 1 --seed 1 -o fasm=$T/trace/$1.fasm > $T/trace/$1.log 2>&1
echo rc $?; cmp $T/trace/$1.fasm $N/board-$2.fasm | head -1; tail -1 $T/trace/$1.log
