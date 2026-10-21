#!/usr/bin/env bash
# Build the tools the project files call, from the submodules under deps/.
#
#   scripts/build-deps.sh [tool ...]     tools: verilator yosys nextpnr fasm2netlist prjxray cudd sta ofl venv
#                                        (default: all of them)
#
# Builds go under build-deps/ and install into build-deps/prefix where the
# tool allows it.  verilator and yosys build in their own tree regardless (their
# makefiles write bin/ and obj_* beside the sources), so .gitmodules marks
# those checkouts ignore=dirty.  Project files refer to the result as {prefix}.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
deps=$root/deps
xc7=$deps/xc7-bitstream-tools
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

yosys() {
    say yosys
    git -C "$xc7" submodule update --init --recursive yosys
    # a plain `make` here: the repository target uses nproc, which macOS lacks
    local extra=()
    if [ "$(uname -s)" = Darwin ]; then
        extra=(CONFIG=clang ENABLE_TCL=0 ENABLE_READLINE=0 ENABLE_EDITLINE=0 ENABLE_PLUGINS=0
               ENABLE_LIBYOSYS=0 ENABLE_ABC=1 PREFIX="$prefix")
        # in the environment, not on the command line: the makefile appends its own -I. to these
        export CXXFLAGS="-I$(brew --prefix libffi)/include" LINKFLAGS="-L$(brew --prefix libffi)/lib"
    fi
    make -C "$xc7/yosys" -j"$jobs" "${extra[@]}"
    test -x "$xc7/yosys/yosys"
}

prjxray() {
    say prjxray tools
    git -C "$xc7" submodule update --init --recursive prjxray
    cmake -S "$xc7/prjxray" -B "$xc7/prjxray/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$xc7/prjxray/build" --target bitread xc7frames2bit --parallel "$jobs"
}

nextpnr() {
    say nextpnr-himbaechel
    git -C "$xc7" submodule update --init --recursive nextpnr
    cmake -S "$xc7/nextpnr" -B "$out/nextpnr" -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DHIMBAECHEL_XILINX_DEVICES="xc7a50t;xc7vx485t" \
        -DHIMBAECHEL_PRJXRAY_DB="$deps/prjxray-db" -DCMAKE_BUILD_TYPE=Release \
        -DBoost_ROOT="$(brew --prefix boost 2>/dev/null || echo /usr)" \
        -DEigen3_DIR="$(brew --prefix eigen 2>/dev/null)/share/eigen3/cmake"
    cmake --build "$out/nextpnr" --target nextpnr-himbaechel --parallel "$jobs"
}

fasm2netlist() {
    say fasm2netlist
    git -C "$xc7" submodule update --init --recursive fasm2netlist
    cmake -S "$xc7/fasm2netlist" -B "$out/fasm2netlist" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$out/fasm2netlist" --parallel "$jobs"
}

cudd() {
    say cudd
    # autotools build in tree (OpenSTA needs it for its BDD package)
    cd "$deps/cudd"
    [ -f configure ] || autoreconf -fi
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
    git -C "$xc7" submodule update --init --recursive prjxray
    python3 -m venv "$out/venv"
    # requirements.txt names its editable installs relative to prjxray/
    (cd "$xc7/prjxray" && "$out/venv/bin/python" -m pip install -q -r requirements.txt -e third_party/fasm)
}

tools=("$@")
[ ${#tools[@]} -gt 0 ] || tools=(verilator yosys prjxray nextpnr fasm2netlist sta ofl venv)
for t in "${tools[@]}"; do ( "$t" ); done
