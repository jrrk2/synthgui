#!/usr/bin/env python3
"""Copy the tools the flow runs into DEST (synthgui.app/Contents/Resources) and make them relocatable.

    scripts/bundle-tools.py DEST

DEST gets the same layout the checkout has beside build/, because synthgui's {root}/{deps}/{prefix}/{builds} are
resolved from it (Project::repoRoot):

    build-deps/prefix/{bin,share}      verilator, sta, openFPGALoader
    build-deps/nextpnr/                nextpnr-himbaechel and the chip databases
    build-deps/fasm2netlist/           tileverilog, lvs_equiv
    build-deps/prjxray/tools/          xc7frames2bit
    build-deps/lib/                    every non-system dylib the above load, re-pointed with @loader_path
    deps/prjxray-db                    the database fasm2frames, tileverilog, lvs_equiv and xc7frames2bit read (FAMILIES,
                                       default artix7 virtex7)

Everything is copied from this checkout's build-deps/ and deps/ (scripts/build-deps.sh builds them). No file under
/opt/homebrew is referenced afterwards. System perl (/usr/bin/perl, for verilator) and the macOS system libraries are the
only things used from the host. There is no Python: the converters the flow needs (FASM to frames, UF2, the STA and block
RAM scripts) are built into synthgui itself (`synthgui --tool NAME`, see tools/), so the bundle holds only the tools that
have their own maintainers, each as its own executable.
"""
import os, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = Path(sys.argv[1]).resolve()
FAMILIES = os.environ.get("FAMILIES", "artix7 virtex7").split()
DEVICES = os.environ.get("CHIPDBS", "xc7a50t xc7vx485t").split()
BD = ROOT / "build-deps"
def run(*a, **k):
    return subprocess.run(a, check=True, capture_output=True, text=True, **k).stdout

def copy(src, dst, skip=()):
    src, dst = Path(src), Path(dst)
    if not src.exists():
        sys.exit("missing: %s" % src)
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=False, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git", *skip))
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

def is_macho(p):
    try:
        with open(p, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")
    except OSError:
        return False

def load_cmds(p):
    out = run("otool", "-L", str(p)).splitlines()[1:]
    return [l.split(" (")[0].strip() for l in out if l.startswith("\t")]

def rpaths(p):
    out = run("otool", "-l", str(p)).splitlines()
    return [out[i + 2].split("path ", 1)[1].split(" (")[0] for i, l in enumerate(out) if "cmd LC_RPATH" in l]

def is_system(n):
    return n.startswith("/usr/lib/") or n.startswith("/System/")

BREW = [Path("/opt/homebrew/lib")] + sorted(Path("/opt/homebrew/opt").glob("*/lib"))

def resolve(name, owner, orig_dirs):
    """The real file an install name refers to, or None."""
    if name.startswith("@rpath/") or name.startswith("@loader_path/") or name.startswith("@executable_path/"):
        tail = name.split("/", 1)[1]
        cands = []
        for d in [owner.parent] + [Path(x) for x in orig_dirs]:
            cands.append(d / tail)
        for r in rpaths(owner):
            cands.append(Path(r.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(owner.parent))) / tail)
        cands += [b / tail for b in BREW] + [b / Path(tail).name for b in BREW]
        cands += sorted(Path('/opt/homebrew/Cellar').glob('*/*/lib/' + Path(tail).name))
        for c in cands:
            if c.exists():
                return c.resolve()
        return None
    p = Path(name)
    if p.exists():
        return p.resolve()
    old = sorted(Path('/opt/homebrew/Cellar').glob('*/*/lib/' + p.name))   # a library Homebrew has since upgraded
    return old[-1].resolve() if old else None

def main():
    res = DEST
    for d in ("build-deps", "deps"):     # only what this script makes; xc7/, sta/ and projects/ belong to package-macos.sh
        shutil.rmtree(res / d, ignore_errors=True)
    res.mkdir(parents=True, exist_ok=True)
    bd, deps = res / "build-deps", res / "deps"
    libdir = bd / "lib"
    libdir.mkdir(parents=True)

    # ---- tools
    pre = BD / "prefix"
    for b in ("verilator", "verilator_bin", "sta", "openFPGALoader"):
        copy(pre / "bin" / b, bd / "prefix" / "bin" / b)
    copy(pre / "share" / "verilator", bd / "prefix" / "share" / "verilator")
    copy(pre / "share" / "openFPGALoader", bd / "prefix" / "share" / "openFPGALoader")
    npnr = BD / "nextpnr"
    copy(npnr / "nextpnr-himbaechel", bd / "nextpnr" / "nextpnr-himbaechel")
    for d in DEVICES:
        copy(npnr / "share" / "himbaechel" / "xilinx" / ("chipdb-%s.bin" % d),
             bd / "nextpnr" / "share" / "himbaechel" / "xilinx" / ("chipdb-%s.bin" % d))
    for b in ("tileverilog", "lvs_equiv"):
        copy(BD / "fasm2netlist" / b, bd / "fasm2netlist" / b)
    copy(BD / "prjxray" / "tools" / "xc7frames2bit", bd / "prjxray" / "tools" / "xc7frames2bit")

    # ---- the database the tools read
    for fam in FAMILIES:
        copy(ROOT / "deps" / "prjxray-db" / fam, deps / "prjxray-db" / fam, skip=("harness",))

    # ---- tcl's script library, which sta reads at start
    tcl = None
    for cand in (Path("/opt/homebrew/opt/tcl-tk@8/lib/tcl8.6"), Path("/opt/homebrew/opt/tcl-tk/lib/tcl8.6")):
        if (cand / "init.tcl").exists():
            tcl = cand
    if tcl:
        copy(tcl, bd / "prefix" / "lib" / "tcl8.6", skip=("tzdata", "msgs", "encoding"))
        copy(tcl / "encoding", bd / "prefix" / "lib" / "tcl8.6" / "encoding")

    # ---- every Mach-O: pull in its non-system dylibs and re-point the load commands
    tools = [res / "build-deps", res / "deps"]
    files = [p for t in tools for p in t.rglob("*") if p.is_file() and not p.is_symlink() and is_macho(p)]
    orig_dirs = {}          # copied file -> directories its original dependencies were found in (for @rpath)
    queue = list(files)
    done = {}
    placed = {}             # real source path -> destination in libdir
    for f in files:
        orig_dirs[f] = []
    while queue:
        f = queue.pop()
        if f in done:
            continue
        done[f] = True
        os.chmod(f, os.stat(f).st_mode | 0o200)
        changes = []
        for name in load_cmds(f):
            if is_system(name) or name.startswith("@loader_path/") and (f.parent / name.split("/", 1)[1]).exists():
                continue
            src = resolve(name, f, orig_dirs.get(f, []))
            if src is None:
                if name.startswith("@rpath/") or name.startswith("/opt/homebrew") or name.startswith("/usr/local"):
                    sys.exit("cannot find %s needed by %s" % (name, f))
                continue
            if is_system(str(src)):
                continue
            if src not in placed:
                dst = libdir / src.name
                if dst.exists():
                    sys.exit("two libraries called %s" % src.name)
                shutil.copy2(src, dst)
                os.chmod(dst, 0o755)
                placed[src] = dst
                orig_dirs[dst] = [str(src.parent)]
                queue.append(dst)
            dst = placed[src]
            rel = os.path.relpath(dst, f.parent)
            changes += ["-change", name, "@loader_path/%s" % rel]
        if f.parent == libdir:
            changes += ["-id", "@loader_path/%s" % f.name]
        for r in rpaths(f):
            changes += ["-delete_rpath", r]
        if changes:
            subprocess.run(["install_name_tool", *changes, str(f)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(f)], check=True, capture_output=True)

    # nothing may still point at the host
    bad = []
    for f in [p for t in tools for p in t.rglob("*") if p.is_file() and not p.is_symlink() and is_macho(p)]:
        for n in load_cmds(f) + rpaths(f):
            if "/opt/homebrew" in n or "/usr/local" in n or str(ROOT) in n:
                bad.append((f, n))
    for f, n in bad:
        print("still host-bound:", f.relative_to(res), n)
    size = int(run("du", "-sk", str(res)).split()[0]) // 1024
    print("%s: %d MB, %d libraries, %d host references left" % (res, size, len(placed), len(bad)))
    return 1 if bad else 0

sys.exit(main())
