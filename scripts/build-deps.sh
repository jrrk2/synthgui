#!/usr/bin/env bash
# Build the tools the project files call, from the submodules under deps/.
#
#   scripts/build-deps.sh [tool ...]     tools: verilator nextpnr fasm2netlist prjxray cudd sta ofl venv
#                                        (default: all of them)
#
# Builds go under build-deps/ and install into build-deps/prefix where the
# tool allows it.  verilator builds in its own tree regardless (its makefiles
# write bin/ and obj_* beside the sources), so .gitmodules marks that checkout
# ignore=dirty.  The flow's FASM-to-bitstream script is xc7/convert.py.
# Project files refer to the results as {prefix} and {builds}.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
deps=$root/deps
out=$root/build-deps
prefix=$out/prefix
mkdir -p "$out" "$prefix"

case $(uname -s) in
Darwin) jobs=$(sysctl -n hw.ncpu) ;;
*) jobs=$(nproc) ;;
esac

if [ "$(uname -s)" = Darwin ]; then
    # keg-only Homebrew packages that the builds look for
    brewp() { brew --prefix "$1" 2>/dev/null || true; }
    export PATH="$(brewp bison)/bin:$(brewp flex)/bin:$PATH"
    export PKG_CONFIG_PATH="$(brewp libftdi)/lib/pkgconfig:$(brewp libusb)/lib/pkgconfig:$(brewp hidapi)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

say() { printf '== %s\n' "$*"; }

verilator() {
    say verilator
    git -C "$deps/verilator" submodule update --init --recursive
    mkdir -p "$out/verilator" && cd "$out/verilator"
    [ -f "$deps/verilator/configure" ] || (cd "$deps/verilator" && autoconf)
    [ -f Makefile ] || "$deps/verilator/configure" --prefix="$prefix"
    make -j"$jobs" && make install
}

prjxray() {
    say prjxray tools
    git -C "$deps/prjxray" submodule update --init --recursive
    cmake -S "$deps/prjxray" -B "$out/prjxray" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$out/prjxray" --target bitread xc7frames2bit --parallel "$jobs"
}

nextpnr() {
    say nextpnr-himbaechel
    git -C "$deps/nextpnr" submodule update --init --recursive
    cmake -S "$deps/nextpnr" -B "$out/nextpnr" -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DHIMBAECHEL_XILINX_DEVICES="xc7a50t;xc7vx485t" \
        -DHIMBAECHEL_PRJXRAY_DB="$deps/prjxray-db" -DCMAKE_BUILD_TYPE=Release \
        -DBoost_ROOT="$(brew --prefix boost 2>/dev/null || echo /usr)" \
        -DEigen3_DIR="$(brew --prefix eigen 2>/dev/null)/share/eigen3/cmake"
    cmake --build "$out/nextpnr" --target nextpnr-himbaechel --parallel "$jobs"
}

fasm2netlist() {
    say fasm2netlist
    git -C "$deps/fasm2netlist" submodule update --init --recursive
    # CaDiCaL (built statically from its submodule) is the default solver; linking Homebrew's libz3 as well buys only
    # `--solver libz3` and makes lvs_equiv fail to start when Homebrew moves to another z3 (5.1 -> 5.3 did). LVS_Z3=ON
    # to link it anyway.
    cmake -S "$deps/fasm2netlist" -B "$out/fasm2netlist" -DCMAKE_BUILD_TYPE=Release -DLVS_Z3="${LVS_Z3:-OFF}"
    cmake --build "$out/fasm2netlist" --parallel "$jobs"
}

cudd() {
    say cudd
    # autotools build in tree (OpenSTA needs it for its BDD package)
    cd "$deps/cudd"
    # a git checkout leaves the generated autotools files no newer than their
    # sources, and make would then regenerate them with the automake 1.14 they came from
    touch aclocal.m4 configure Makefile.in config.h.in
    [ -f Makefile ] || ./configure --prefix="$prefix"
    make -j"$jobs" && make install
}

sta() {
    say OpenSTA
    [ -f "$prefix/lib/libcudd.a" ] || cudd
    local tcl; tcl=$(brew --prefix tcl-tk@8 2>/dev/null || true)
    cmake -S "$deps/OpenSTA" -B "$out/OpenSTA" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCUDD_DIR="$prefix" \
        ${tcl:+-DTCL_LIBRARY="$tcl/lib/libtcl8.6.dylib" -DTCL_HEADER="$tcl/include/tcl-tk/tcl.h"}
    cmake --build "$out/OpenSTA" --parallel "$jobs"
    cmake --install "$out/OpenSTA"
}

ofl() {
    say openFPGALoader
    # Homebrew's libusb is linked statically here and needs the Security framework
    local ofl_link=()
    [ "$(uname -s)" = Darwin ] && ofl_link=(-DCMAKE_EXE_LINKER_FLAGS="-framework Security -framework CoreFoundation")
    cmake -S "$deps/openFPGALoader" -B "$out/openFPGALoader" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS=-Wno-c++11-narrowing-const-reference \
        ${ofl_link[@]+"${ofl_link[@]}"} -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
    cmake --build "$out/openFPGALoader" --parallel "$jobs"
    cmake --install "$out/openFPGALoader"
}

venv() {
    say python venv for prjxray fasm2frames
    git -C "$deps/prjxray" submodule update --init --recursive
    python3 -m venv "$out/venv"
    # requirements.txt names its editable installs relative to prjxray/
    (cd "$deps/prjxray" && "$out/venv/bin/python" -m pip install -q -r requirements.txt -e third_party/fasm)
}

tools=("$@")
[ ${#tools[@]} -gt 0 ] || tools=(verilator prjxray nextpnr fasm2netlist sta ofl venv)
for t in "${tools[@]}"; do ( "$t" ); done
