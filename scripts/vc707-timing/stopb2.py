#!/usr/bin/env python3
"""stopb2.py <log>: stop the running sweep on the board console (Ctrl-C) and power Linux off. Port from CONSOLE."""
import os, sys, time, serial
s = serial.Serial(os.environ["CONSOLE"], 115200, timeout=0.5); f = open(sys.argv[1], "ab")
def rd(t):
    e = time.time() + t
    while time.time() < e: f.write(s.read(4096)); f.flush()
for _ in range(3): s.write(b"\x03"); rd(1)
s.write(b"\r\npkill -f sweep2.sh; pkill -f ysweep.sh; pkill -f atctl; sleep 1; echo STOPPED\r\n"); rd(4)
s.write(b"poweroff\r\n"); rd(15)
