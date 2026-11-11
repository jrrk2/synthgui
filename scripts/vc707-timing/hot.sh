#!/bin/bash
# hot.sh <route> <M> <D> <limit C>: trial.sh with an over-temperature stop, reading tlog.sh's live XADC log (5 s period)
D=$HOME/synthgui/runs/2026-11-10-linuxcal; T=$HOME/synthgui/runs/2026-11-05-char/temp5.csv; tag=$1-m$2d$3; lim=$4
cd $D; bash trial.sh $1 $2 $3 > log/$tag.trial.out 2>&1 & tp=$!
max=0; t0=$(date +%s)
while kill -0 $tp 2>/dev/null; do
  l=$(tail -1 $T); e=${l%%,*}; t=$(echo "$l" | cut -d, -f2)
  max=$(awk -v a=$max -v b=$t 'BEGIN{print (b>a)?b:a}')
  echo "$(date +%s),$t" >> log/$tag.temp.csv
  if awk -v t=$t -v l=$lim 'BEGIN{exit !(t>=l)}'; then
    pkill -P $tp; kill $tp; echo "OVERTEMP $t C at $(( $(date +%s)-t0 )) s, trial stopped"; break; fi
  sleep 5
done
echo "max die temperature during trial: $max C"; cat log/$tag.trial.out
