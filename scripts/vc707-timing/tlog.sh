#!/bin/bash
# tlog.sh <csv> [period]: XADC over JTAG, between bitstream loads (shares jtag.lock with console.py)
B=$HOME/synthgui/runs/2026-11-05-silicon; o=$1; p=${2:-5}
[ -s "$o" ] || echo "epoch,temp_c,maxtemp_c,mintemp_c,vccint,vccaux" > "$o"
while :; do
  j=$(flock -w 30 $B/jtag.lock $B/ofl/b/openFPGALoader --cable digilent --read-xadc 2>/dev/null)
  v() { echo "$j" | sed -n "s/.*\"$1\": *\([-0-9.]*\).*/\1/p" | head -1; }
  [ -n "$(v temp)" ] && echo "$(date +%s),$(v temp),$(v maxtemp),$(v mintemp),$(v vccint),$(v vccaux)" >> "$o"
  sleep $p
done
