#!/bin/sh
# timed.sh <tag>: the benchmark route
a=$(cut -d' ' -f1 /proc/uptime)
./nextpnr-himbaechel --device xc7vx485tffg1761-2 --chipdb chipdb-win.bin --json window-new.json -o xdc=window.xdc --router router2 --timing-allow-fail -o hold-fix -o clock-tree=off -o delay-matrix=off -o pr-reserve=reserve-new.txt --threads 1 --seed 1 -o fasm=/tmp/$1.fasm > /tmp/$1.log 2>&1
rc=$?; b=$(cut -d' ' -f1 /proc/uptime)
echo "ROUTE $1 rc=$rc start=$a end=$b"; grep -a "Router2 time" /tmp/$1.log; cmp /tmp/$1.fasm board-new.fasm | head -1; grep -v '^#' /tmp/$1.fasm > /tmp/$1.nc; grep -v '^#' board-new.fasm > /tmp/ref.nc; cmp /tmp/$1.nc /tmp/ref.nc && echo FASM-SAME
