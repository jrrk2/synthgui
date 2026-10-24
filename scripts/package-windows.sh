#!/bin/bash
# Build synthgui for Windows and put it, Qt and the tools the flow runs into one folder that needs nothing installed:
# no MSYS2, no bash, no Perl, no Python.  Run from an MSYS2 MINGW64 shell after scripts/build-deps.sh.
# Output goes to build-release/.
#
#   scripts/package-windows.sh
#   FAMILIES="artix7 virtex7 kintex7" CHIPDBS="xc7a50t xc7vx485t" SYNTHGUI_VERSION=0.2.0 scripts/package-windows.sh
#
# The folder has the layout the checkout has beside build/, because synthgui resolves {root}, {prefix} and {builds}
# from the directory above its executable (Project::repoRoot):
#
#   bin/                               synthgui.exe, Qt (windeployqt) and the MinGW runtime
#   build-deps/prefix/{bin,share,lib}  verilator_bin, sta, openFPGALoader; Tcl's script library for sta
#   build-deps/nextpnr/                nextpnr-himbaechel and the chip databases (CHIPDBS)
#   build-deps/fasm2netlist/           tileverilog, lvs_equiv
#   build-deps/prjxray/tools/          xc7frames2bit
#   deps/prjxray-db                    the families in FAMILIES (default artix7 virtex7)
#   xc7/, projects/, example.json
#
# Windows looks for a program's DLLs beside it first, so every directory with programs gets the MINGW64 DLLs they load.
# synthgui runs the step commands itself (directPieces in main.cpp), so no shell is needed. Not signed (Authenticode is
# a separate step).
set -euo pipefail
cd "$(dirname "$0")/.."
case $(uname -s) in MINGW64*) ;; *) echo "run this from an MSYS2 MINGW64 shell" >&2; exit 1 ;; esac
VER=${SYNTHGUI_VERSION:-$(sed -n 's/^set(SYNTHGUI_VERSION "\([^"]*\)".*/\1/p' CMakeLists.txt)}
FAMILIES=${FAMILIES:-artix7 virtex7}
CHIPDBS=${CHIPDBS:-xc7a50t xc7vx485t}
B=build-release
OUT=$B/synthgui-$VER-windows-x64
BD=build-deps

cmake -S . -B $B/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSYNTHGUI_VERSION="$VER" >/dev/null
cmake --build $B/build --parallel "${JOBS:-$(nproc)}"

rm -rf "$OUT"
mkdir -p "$OUT/bin"
copy() {  # copy SRC DST, creating DST's directory
    [ -e "$1" ] || { echo "missing: $1 (scripts/build-deps.sh builds it)" >&2; exit 1; }
    mkdir -p "$(dirname "$2")"
    cp -R "$1" "$2"
}

# ---- synthgui and Qt; offscreen too, for headless batch runs (QT_QPA_PLATFORM=offscreen)
cp $B/build/synthgui.exe "$OUT/bin/"
windeployqt6 --release --no-translations --no-system-d3d-compiler --no-opengl-sw "$OUT/bin/synthgui.exe" >/dev/null
mkdir -p "$OUT/bin/platforms"
cp "$(qtpaths6 --query QT_INSTALL_PLUGINS)/platforms/qoffscreen.dll" "$OUT/bin/platforms/"

# ---- the tools with their own maintainers, as separate executables
for b in verilator_bin sta openFPGALoader; do copy $BD/prefix/bin/$b.exe "$OUT/$BD/prefix/bin/$b.exe"; done
copy $BD/prefix/share/verilator "$OUT/$BD/prefix/share/verilator"
copy $BD/prefix/share/openFPGALoader "$OUT/$BD/prefix/share/openFPGALoader"
rm -rf "$OUT/$BD/prefix/share/verilator/examples"
copy $BD/nextpnr/nextpnr-himbaechel.exe "$OUT/$BD/nextpnr/nextpnr-himbaechel.exe"
for d in $CHIPDBS; do
    copy $BD/nextpnr/share/himbaechel/xilinx/chipdb-$d.bin "$OUT/$BD/nextpnr/share/himbaechel/xilinx/chipdb-$d.bin"
done
for b in tileverilog lvs_equiv; do copy $BD/fasm2netlist/$b.exe "$OUT/$BD/fasm2netlist/$b.exe"; done
copy $BD/prjxray/tools/xc7frames2bit.exe "$OUT/$BD/prjxray/tools/xc7frames2bit.exe"
# tcl86.dll finds its script library at ../lib/tcl8.6 from the directory it is loaded from
copy /mingw64/lib/tcl8.6 "$OUT/$BD/prefix/lib/tcl8.6"
rm -rf "$OUT/$BD/prefix/lib/tcl8.6/tzdata"

# ---- the database the tools read; the example projects without the Sonata Linux tree
for fam in $FAMILIES; do
    mkdir -p "$OUT/deps/prjxray-db"
    cp -R deps/prjxray-db/$fam "$OUT/deps/prjxray-db/"
    rm -rf "$OUT/deps/prjxray-db/$fam/harness"
done
cp -R xc7 "$OUT/"
rm -rf "$OUT"/xc7/__pycache__ "$OUT"/xc7/*.py   # the reference the built-in tools (tools/) were checked against
mkdir -p "$OUT/projects"
tar -C projects --exclude linux --exclude '*.log' -cf - . | tar -C "$OUT/projects" -xf -
cp example.json "$OUT/"

# ---- every directory with programs gets the MINGW64 DLLs they (and, under bin/, the Qt plugins) load
dlls() {  # the non-system DLLs FILE... load, as MSYS paths
    ldd "$@" 2>/dev/null | sed -n 's|.* => \(/mingw64/[^ ]*\) .*|\1|p' | sort -u
}
for dir in "$OUT/bin" "$OUT/$BD/prefix/bin" "$OUT/$BD/nextpnr" "$OUT/$BD/fasm2netlist" "$OUT/$BD/prjxray/tools"; do
    if [ "$dir" = "$OUT/bin" ]; then files=$(find "$dir" -name '*.exe' -o -name '*.dll'); else files=$(ls "$dir"/*.exe); fi
    # repeat until nothing new: a copied DLL can need others
    while :; do
        new=0
        # shellcheck disable=SC2086
        for d in $(dlls $files $(ls "$dir"/*.dll 2>/dev/null)); do
            [ -f "$dir/$(basename "$d")" ] || { cp "$d" "$dir/"; new=1; }
        done
        [ $new = 1 ] || break
    done
done

# ---- nothing may still come from MSYS2: run each program with only Windows on the PATH
bad=0
for exe in "$OUT/bin/synthgui.exe" "$OUT/$BD/prefix/bin/"*.exe "$OUT/$BD/nextpnr/"*.exe "$OUT/$BD/fasm2netlist/"*.exe \
           "$OUT/$BD/prjxray/tools/"*.exe; do
    if PATH=/c/Windows/System32 /usr/bin/ldd "$exe" | grep -q "/mingw64/\|not found"; then
        echo "still needs MSYS2: $exe" >&2
        PATH=/c/Windows/System32 /usr/bin/ldd "$exe" | grep "/mingw64/\|not found" >&2
        bad=1
    fi
done
echo "$OUT: $(du -sm "$OUT" | cut -f1) MB"
exit $bad
