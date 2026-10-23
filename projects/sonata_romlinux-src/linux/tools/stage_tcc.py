#!/usr/bin/env python3
"""Lay out the on-board C compiler tree, the way Buildroot's package/tcc/tcc.mk installs it:

    usr/bin/tcc  usr/lib/tcc/libtcc1.a  usr/lib/tcc/include/*.h
    usr/include (musl headers + the Linux kernel headers a program needs)
    usr/lib/{crt1,crti,crtn}.o  usr/lib/libc.a (+ the empty libm.a etc.)  usr/lib/libgcc.a

usage: stage_tcc.py --tinycc DIR --sysroot DIR --libgcc FILE --gcc CMD --strip TOOL --out DIR
The kernel headers are trimmed to the closure of the ones in KERNEL_SEEDS (the full set is 7 MB); CMD is the
riscv32 cross compiler used to compute that closure."""
import argparse, os, pathlib, re, shutil, subprocess, sys, tempfile

KERNEL_SEEDS = """linux/fb.h linux/input.h linux/input-event-codes.h linux/i2c.h linux/i2c-dev.h linux/spi/spidev.h
linux/gpio.h linux/ioctl.h linux/types.h linux/fcntl.h linux/limits.h linux/time.h linux/kd.h linux/vt.h
linux/serial.h linux/if.h linux/if_ether.h linux/in.h linux/socket.h linux/sockios.h linux/errno.h
linux/netlink.h linux/rtnetlink.h linux/if_packet.h linux/termios.h linux/sched.h linux/futex.h linux/mman.h
linux/stat.h linux/random.h linux/reboot.h linux/ethtool.h linux/watchdog.h linux/rtc.h linux/uinput.h""".split()
KERNEL_DIRS = {"linux", "asm", "asm-generic", "drm", "misc", "mtd", "rdma", "scsi", "sound", "video", "xen"}

ap = argparse.ArgumentParser()
for a in ("tinycc", "sysroot", "libgcc", "gcc", "strip", "out"):
    ap.add_argument("--" + a, required=True)
args = ap.parse_args()
out = pathlib.Path(args.out)
sysroot = pathlib.Path(args.sysroot)
if out.exists():
    shutil.rmtree(out)
inc = sysroot / "usr/include"

def install(src, dst, mode=0o644):
    dst = out / dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    dst.chmod(mode)

# the compiler and its own files
install(pathlib.Path(args.tinycc) / "tcc", "usr/bin/tcc", 0o755)
subprocess.run([args.strip, "-s", str(out / "usr/bin/tcc")], check=True)
install(pathlib.Path(args.tinycc) / "libtcc1.a", "usr/lib/tcc/libtcc1.a")
for h in sorted((pathlib.Path(args.tinycc) / "include").glob("*.h")):
    install(h, "usr/lib/tcc/include/" + h.name)

# musl headers (everything that is not a kernel header directory)
for p in sorted(inc.rglob("*")):
    rel = p.relative_to(inc)
    if p.is_file() and rel.parts[0] not in KERNEL_DIRS:
        install(p, "usr/include/" + str(rel))

# the kernel headers: the closure of the seeds, found with the preprocessor
with tempfile.TemporaryDirectory() as t:
    seed = pathlib.Path(t) / "seed.c"
    seed.write_text("".join("#if __has_include(<%s>)\n#include <%s>\n#endif\n" % (h, h) for h in KERNEL_SEEDS))
    dep = subprocess.run(args.gcc.split() + ["-M", str(seed)], capture_output=True, text=True, check=True).stdout
deps = re.findall(r"\S+", dep.replace("\\\n", " "))
for d in deps:
    if d.startswith(str(inc)) and pathlib.Path(d).is_file():
        rel = pathlib.Path(d).relative_to(inc)
        if rel.parts[0] in KERNEL_DIRS:
            install(d, "usr/include/" + str(rel))

# C library, start files, libgcc (symbols only: debug info is 40% of the archive)
lib = sysroot / "usr/lib"
for name in ("crt1.o", "crti.o", "crtn.o"):
    install(lib / name, "usr/lib/" + name)
for a in sorted(lib.glob("*.a")):
    install(a, "usr/lib/" + a.name)
    subprocess.run([args.strip, "--strip-debug", str(out / "usr/lib" / a.name)], check=True)
install(args.libgcc, "usr/lib/libgcc.a")
subprocess.run([args.strip, "--strip-debug", str(out / "usr/lib/libgcc.a")], check=True)

total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
print("%s: %d files, %.1f MB" % (out, sum(1 for f in out.rglob("*") if f.is_file()), total / 1e6))
