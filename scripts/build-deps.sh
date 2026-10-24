#!/usr/bin/env bash
# Build the tools the project files call, from the submodules under deps/.
#
#   scripts/build-deps.sh [tool ...]     tools: verilator nextpnr fasm2netlist prjxray cudd sta ofl venv
#                                        (usblibs: libusb, hidapi, libftdi for ofl on Windows)
#                                        (default: all of them)
#   CHIPDBS=xc7a50t scripts/build-deps.sh nextpnr
#                                        only these chip databases (default xc7a50t xc7vx485t); the 485t's takes
#                                        several GB of memory to make, so where that is short make it on a run of its own
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
jobs=${JOBS:-$jobs}  # JOBS=n to limit parallel compiles where memory is short

# Windows: run from an MSYS2 MINGW64 shell.  The MSYS tools (bash, make, autoconf, bison, flex, perl)
# configure and generate; MINGW64 gcc compiles, so the results are native executables.
mingw=
case $(uname -s) in MINGW*) mingw=1 ;; esac

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
    local libs=(-DBoost_ROOT="$(brew --prefix boost 2>/dev/null || echo /usr)" -DEigen3_DIR="$(brew --prefix eigen 2>/dev/null)/share/eigen3/cmake")
    # MINGW64: Boost and Eigen are in its prefix, where CMake looks anyway; no LTO, whose objects the PE linker rejects
    # ("defined in discarded section .gnu.linkonce")
    if [ "$mingw" ]; then libs=(-DUSE_IPO=OFF); fi
    cmake -S "$deps/nextpnr" -B "$out/nextpnr" -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DHIMBAECHEL_XILINX_DEVICES="$(echo ${CHIPDBS:-xc7a50t xc7vx485t} | tr ' ' ';')" \
        -DHIMBAECHEL_PRJXRAY_DB="$deps/prjxray-db" -DCMAKE_BUILD_TYPE=Release \
        ${libs[@]+"${libs[@]}"}
    cmake --build "$out/nextpnr" --target nextpnr-himbaechel --parallel "$jobs"
}

fasm2netlist() {
    say fasm2netlist
    git -C "$deps/fasm2netlist" submodule update --init --recursive
    local cadical=()
    if [ "$mingw" ]; then
        # its CMake builds the CaDiCaL submodule with ./configure, which cmd.exe cannot run: build it here
        # and hand it over as an installed copy
        (cd "$deps/fasm2netlist/third_party/cadical" && { [ -f build/makefile ] || ./configure; } &&
            make -C build -j"$jobs" libcadical.a)
        mkdir -p "$prefix/include" "$prefix/lib"
        cp "$deps/fasm2netlist/third_party/cadical/src/cadical.hpp" "$prefix/include/"
        cp "$deps/fasm2netlist/third_party/cadical/build/libcadical.a" "$prefix/lib/"
        cadical=(-DCADICAL_ROOT="$prefix")
    fi
    # CaDiCaL (built statically from its submodule) is the default solver; linking Homebrew's libz3 as well buys only
    # `--solver libz3` and makes lvs_equiv fail to start when Homebrew moves to another z3 (5.1 -> 5.3 did). LVS_Z3=ON
    # to link it anyway.
    cmake -S "$deps/fasm2netlist" -B "$out/fasm2netlist" -DCMAKE_BUILD_TYPE=Release -DLVS_Z3="${LVS_Z3:-OFF}" \
        ${cadical[@]+"${cadical[@]}"}
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
    local win=()
    if [ "$mingw" ]; then
        # the unit tests need GTest and POSIX headers; the flow only runs sta.  FlexLexer.h comes with
        # the MSYS flex, but /usr/include as an include directory would hide the MINGW64 C headers
        mkdir -p "$prefix/include/flex"
        cp /usr/include/FlexLexer.h "$prefix/include/flex/"
        win=(-DBUILD_TESTS=OFF -DFLEX_INCLUDE_DIR="$prefix/include/flex")
    fi
    cmake -S "$deps/OpenSTA" -B "$out/OpenSTA" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCUDD_DIR="$prefix" \
        ${win[@]+"${win[@]}"} \
        ${tcl:+-DTCL_LIBRARY="$tcl/lib/libtcl8.6.dylib" -DTCL_HEADER="$tcl/include/tcl-tk/tcl.h"}
    cmake --build "$out/OpenSTA" --parallel "$jobs"
    cmake --install "$out/OpenSTA"
}

usblibs() {
    say libusb hidapi libftdi
    # MSYS2 no longer packages these for MINGW64: build them static into the prefix from release sources
    local src=$out/src
    mkdir -p "$src"
    [ -d "$src/libusb" ] || git clone -q --depth 1 -b v1.0.27 https://github.com/libusb/libusb.git "$src/libusb"
    [ -d "$src/hidapi" ] || git clone -q --depth 1 -b hidapi-0.14.0 https://github.com/libusb/hidapi.git "$src/hidapi"
    if [ ! -d "$src/libftdi1-1.5" ]; then
        curl -sSLf -o "$src/libftdi1-1.5.tar.bz2" https://www.intra2net.com/en/developer/libftdi/download/libftdi1-1.5.tar.bz2
        tar -C "$src" -xjf "$src/libftdi1-1.5.tar.bz2"
    fi
    (cd "$src/libusb" && { [ -f configure ] || ./bootstrap.sh; } &&
        mkdir -p "$out/libusb" && cd "$out/libusb" &&
        { [ -f Makefile ] || "$src/libusb/configure" --prefix="$prefix" --disable-shared; } &&
        make -j"$jobs" && make install)
    cmake -S "$src/hidapi" -B "$out/hidapi" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF -DHIDAPI_BUILD_HIDTEST=OFF
    cmake --build "$out/hidapi" --parallel "$jobs" && cmake --install "$out/hidapi"
    cmake -S "$src/libftdi1-1.5" -B "$out/libftdi" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_PREFIX_PATH="$prefix" -DSTATICLIBS=ON -DEXAMPLES=OFF -DFTDI_EEPROM=OFF \
        -DPYTHON_BINDINGS=OFF -DDOCUMENTATION=OFF
    cmake --build "$out/libftdi" --parallel "$jobs" && cmake --install "$out/libftdi"
}

ofl() {
    say openFPGALoader
    local win=()
    if [ "$mingw" ]; then
        [ -f "$prefix/lib/libftdi1.a" ] || usblibs
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
        win=(-DBUILD_STATIC=ON)
    fi
    # Homebrew's libusb is linked statically here and needs the Security framework
    local ofl_link=()
    [ "$(uname -s)" = Darwin ] && ofl_link=(-DCMAKE_EXE_LINKER_FLAGS="-framework Security -framework CoreFoundation")
    cmake -S "$deps/openFPGALoader" -B "$out/openFPGALoader" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS=-Wno-c++11-narrowing-const-reference \
        ${ofl_link[@]+"${ofl_link[@]}"} ${win[@]+"${win[@]}"} -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
    cmake --build "$out/openFPGALoader" --parallel "$jobs"
    cmake --install "$out/openFPGALoader"
}

venv() {
    say python venv for prjxray fasm2frames
    git -C "$deps/prjxray" submodule update --init --recursive
    if [ "$mingw" ]; then
        # pip cannot build numpy and scipy here: take MSYS2's builds and let pip add the pure-Python rest
        pacman -S --needed --noconfirm mingw-w64-x86_64-python-{numpy,scipy,yaml,openpyxl,pytest,intervaltree,ordered-set}
        python3 -m venv --system-site-packages "$out/venv"
    else
        python3 -m venv "$out/venv"
    fi
    # requirements.txt names its editable installs relative to prjxray/
    (cd "$deps/prjxray" && "$out/venv/bin/python" -m pip install -q -r requirements.txt -e third_party/fasm)
}

tools=("$@")
if [ ${#tools[@]} -eq 0 ]; then
    tools=(verilator prjxray nextpnr fasm2netlist sta ofl venv)
    # nothing in the flow runs Python any more (tools/ are built into synthgui): no venv by default on Windows
    if [ "$mingw" ]; then tools=(verilator prjxray nextpnr fasm2netlist sta ofl); fi
fi
for t in "${tools[@]}"; do ( "$t" ); done
