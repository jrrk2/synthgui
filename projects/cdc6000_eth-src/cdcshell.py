#!/usr/bin/env python3
"""cdcshell.py [--bit FILE] COMMAND...: type commands at the CDC 6000 shell on the
VC707 (vc707_cdc_eth: the UART at 115200 8N1, plain text) and print what it
answers, each up to its next prompt ("cdc:...> ").

    cdcshell.py --bit vc707_cdc_eth.bit help "compile pascal"

With --bit the board is reprogrammed first, after the port is open, so the
shell's banner is not missed.  A command's output ends at the next prompt or
after --timeout seconds of it."""
import argparse, re, subprocess, sys, time

import serial

PROMPT = re.compile(rb"cdc:[^\n]*> $")


def until_prompt(port, timeout):
    out = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = port.read(256)
        if b:
            out.extend(b)
            sys.stdout.write(b.decode("ascii", "replace").replace("\r", ""))
            sys.stdout.flush()
            if PROMPT.search(bytes(out[-200:])):
                return bytes(out)
    sys.exit("\ncdcshell: no prompt within %g s" % timeout)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("commands", nargs="*")
    ap.add_argument("--port", default="/dev/ttyUSB2")
    ap.add_argument("--bit", help="reprogram the FPGA with this bitstream first")
    ap.add_argument("--loader", default="openFPGALoader")
    ap.add_argument("--timeout", type=float, default=600, help="seconds a command may take")
    a = ap.parse_args()

    try:
        # exclusive: a terminal (picocom, screen) left on the port takes half of every read
        port = serial.Serial(a.port, 115200, timeout=0.2, exclusive=True)
    except serial.SerialException as e:
        sys.exit("cdcshell: %s (is a terminal open on %s?)" % (e, a.port))
    port.reset_input_buffer()
    if a.bit:
        subprocess.run([a.loader, "--cable", "digilent", "--freq", "15000000", a.bit], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until_prompt(port, 60)
    else:
        port.write(b"\r")
        until_prompt(port, 10)
    for c in a.commands:
        port.write(c.encode("ascii") + b"\r")
        until_prompt(port, a.timeout)
    print()


if __name__ == "__main__":
    main()
