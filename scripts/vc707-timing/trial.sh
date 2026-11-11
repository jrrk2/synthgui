#!/bin/bash
# trial.sh <route> <M> <D>: load retime/<route>-m<M>d<D>/harness.bit by JTAG, boot Linux (TFTP+NFS), run 05-silicon's FP test set
D=$HOME/synthgui/runs/2026-11-10-linuxcal; S=$HOME/synthgui/runs/2026-11-05-silicon; R=$HOME/synthgui/runs/2026-11-04-fpu; t=$1-m$2d$3
TESTS="mount --bind / /mnt; cd /mnt/tmp/pnr; ./fptest2; ./fptest2; ./fptest2; ./fptest; ./fptest; ./fpeq | tail -1; ./fpcmp | tail -1"
# the CP2103 by id: ttyUSB numbering changes with the board and with plug order
export CONSOLE=${CONSOLE:-/dev/serial/by-id/usb-Silicon_Labs_CP2103_USB_to_UART_Bridge_Controller_0001-if00-port0}
python3 $S/console.py $D/log/$t-boot.log $D/retime/$t/harness.bit - 240 $CONSOLE
grep -a -m1 -o 'sys [0-9.]* MHz' $D/log/$t-boot.log
tail -c 300 $D/log/$t-boot.log | tr -d '\r' | tail -4
grep -aq 'login: ' $D/log/$t-boot.log && python3 $R/board.py $D/log/$t.log 300 "$TESTS" >/dev/null 2>&1 && grep -a -E 'fpcheck|violations|branches' $D/log/$t.log
tail -1 $S/temp.csv
