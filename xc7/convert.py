#!/usr/bin/env python3
"""FASM to raw XC7 bitstream through Project X-Ray.

  convert.py --arch xilinx --family xc7 --part PART --db prjxray-db --fasm in.fasm --output out.bit

Uses deps/prjxray (the submodule) and its xc7frames2bit, built by scripts/build-deps.sh.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PRJXRAY = ROOT / "deps" / "prjxray"
FRAMES2BIT = ROOT / "build-deps" / "prjxray" / "tools" / "xc7frames2bit"

FAMILIES = {"xc7a": "artix7", "xc7k": "kintex7", "xc7s": "spartan7", "xc7v": "virtex7", "xc7z": "zynq7"}


def family_for_part(part):
    for prefix, family in FAMILIES.items():
        if part.startswith(prefix):
            return family
    raise ValueError("Unsupported XC7 part: %s" % part)


def fasm_to_bit(part, database_root, fasm, allow_missing_features=False):
    # The wrapper, not prjxray's script directly: it swaps in the line-oriented
    # FASM reader, which is much faster on the parse (see fasm_fast.py).
    fasm2frames = HERE / "fasm2frames_fast.py"
    family = family_for_part(part)
    part_dir = database_root / family / part
    for path in (fasm2frames, FRAMES2BIT, part_dir / "part.yaml", fasm):
        if not path.exists():
            raise FileNotFoundError(path)
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(PRJXRAY) + os.pathsep + environment.get("PYTHONPATH", "")
    if allow_missing_features:
        environment["XRAY_ALLOW_MISSING_FEATURES"] = "1"
    with tempfile.TemporaryDirectory() as tmp:
        frames = Path(tmp) / "design.frames"
        bitstream = Path(tmp) / "design.bit"
        subprocess.run([sys.executable, str(fasm2frames), "--part", part, "--db-root", str(database_root / family),
                        str(fasm), str(frames)], check=True, env=environment)
        subprocess.run([str(FRAMES2BIT), "--part_file", str(part_dir / "part.yaml"), "--part_name", part,
                        "--frm_file", str(frames), "--output_file", str(bitstream)], check=True)
        return bitstream.read_bytes()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--arch", required=True)
    p.add_argument("--family", required=True)
    p.add_argument("--part", required=True, help="Full FPGA part name")
    p.add_argument("--db", type=Path, required=True, help="Project X-Ray database root")
    p.add_argument("--fasm", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--allow-missing-features", action="store_true")
    a = p.parse_args()
    if (a.arch, a.family) != ("xilinx", "xc7"):
        print("No conversion backend for %s/%s; no output generated." % (a.arch, a.family))
        return 0
    a.output.write_bytes(fasm_to_bit(a.part, a.db, a.fasm, a.allow_missing_features))
    print("Wrote %s" % a.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
