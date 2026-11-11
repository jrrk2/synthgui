#!/bin/bash
# yrun20.sh <tag> <image:prefix>...: wait until the die temperature has levelled (under 0.3 C rise in 3 min), run ysweep.sh with the list, watch it.
# Exits, with the reason on the last line, on done, on no new data for 240 s, or on the JTAG chip leaving USB.
R=$HOME/synthgui/runs/2026-11-05-char; D=$HOME/vc707-nfsroot/tmp/char/d6; tag=$1; shift
# NOWAIT=1 skips the level wait (2026-11-11 board 2: record while the die warms, temperature from temp5.csv)
[ -n "$NOWAIT" ] && a=- && b=$(tail -1 $R/temp5.csv | cut -d, -f2)
while [ -z "$NOWAIT" ]; do
  a=$(awk -F, -v c=$(( $(date +%s) - 180 )) 'NR>1 && $1<=c {t=$2} END{print t}' $R/temp5.csv); b=$(tail -1 $R/temp5.csv | cut -d, -f2)
  [ -n "$a" ] && awk -v a="$a" -v b="$b" 'BEGIN{exit !(b-a<0.3)}' && break; sleep 20; done
echo "$(date +%T) level at $b C (3 min ago $a)"
n0=$(grep -c . $D/yloads.txt 2>/dev/null || echo 0)
setsid -f python3 $HOME/synthgui/runs/2026-11-04-fpu/board.py $R/log/board-$tag.log 28800 "mountpoint -q /mnt || mount --bind / /mnt" "cd /mnt/tmp/char" "./atctl tfreq" "./ysweep.sh $*" > $R/log/board-$tag.out 2>&1 < /dev/null
echo "$(date +%T) started: $*"
last=-1; since=$(date +%s)
while :; do
  sleep 30
  grep -qs "YSWEEPDONE $*" $D/yloads.txt && { echo "$(date +%T) DONE"; exit 0; }
  lsusb -d 0403:6010 > /dev/null || { echo "$(date +%T) STOPPED: FT2232 off USB; newest $(ls -t $D | head -1)"; exit 3; }
  n=$(stat -c %s $D/*.txt | awk '{s+=$1} END{print s}')
  if [ "$n" != "$last" ]; then last=$n; since=$(date +%s); fi
  [ $(( $(date +%s) - since )) -gt 240 ] && { echo "$(date +%T) STOPPED: no data for 240 s; newest $(ls -t $D | head -1)"; exit 4; }
done
