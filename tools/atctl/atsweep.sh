#!/bin/sh
# atsweep.sh <out> : capture-phase sweep, raw LFSR counters, VCO 1400 MHz launch 100 MHz, 714 ps per cdelay
o=$1; : > $o
for cd in 0 1 2 3 4 5 6; do for cm in 0 1 2 3 4 5 6 7; do
  ./atctl tmmcm 14 2 14 $cm $cd > /dev/null
  ./atctl at 50000 > /dev/null
  echo "$cd $cm $(./atctl atread 5 | sed 's/.*: //; s/ errors//' | tr '\n' ' ')" >> $o
done; done
