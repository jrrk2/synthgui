#!/bin/bash
# step.sh <route> <M,D>...: hot.sh (80 C stop) at each clock in order, stop at the first that does not pass.
# Pass = login prompt, fptest2 x3 af41ac2fe8fa931d, fptest x2 2a2c4ef7aebbddfd, fpeq 0/0/0, fpcmp 0 violations.
D=$HOME/synthgui/runs/2026-11-10-linuxcal; r=$1; shift; cd $D
for md in "$@"; do m=${md%,*}; d=${md#*,}; t=$r-m${m}d$d
  until [ -s retime/$t/harness.bit ] && grep -q RETIMEDONE retime/$t.log 2>/dev/null; do sleep 20; done
  out=$(bash hot.sh $r $m $d 80); l=log/$t.log
  a=$(tr -d '\r' < $l 2>/dev/null | grep -c '^fpcheck af41ac2fe8fa931d'); b=$(tr -d '\r' < $l 2>/dev/null | grep -c '^fpcheck 2a2c4ef7aebbddfd')
  e=$(tr -d '\r' < $l 2>/dev/null | grep -c 'branches: v\[i-1\]>v\[i\] 0, !(v\[i\]>=v\[0\]) 0, !(v\[i\]<=v\[n-1\]) 0'); c=$(tr -d '\r' < $l 2>/dev/null | grep -c 'sorts 3000, order violations 0')
  mhz=$(awk -v m=$m -v d=$d 'BEGIN{printf "%.2f", 200*m/(12*d)}'); mx=$(echo "$out" | sed -n 's/max die temperature during trial: //p')
  if [ "$a" = 3 ] && [ "$b" = 2 ] && [ "$e" = 1 ] && [ "$c" = 1 ]; then echo "$t $mhz MHz PASS (max $mx)"; else
    echo "$t $mhz MHz FAIL (max $mx): $(tr -d '\r' < log/$t-boot.log | grep -a -m1 -o -E 'Memtest KO|Kernel panic[^!]*|no login' ; echo "$out" | grep -m1 -E 'no login|OVERTEMP')"; echo "$out" | tail -6; exit 1; fi
done
