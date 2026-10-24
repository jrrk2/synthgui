#!/bin/bash
# Put synthgui, its Qt and the tools the flow runs into one folder, and make a tarball of it. For Ubuntu 24.04 (x86-64);
# elsewhere build from source (README.md). Run after scripts/build-deps.sh. Output goes to build-release/.
#
#   scripts/package-linux.sh
#   FAMILIES="artix7 virtex7 kintex7" CHIPDBS="xc7a50t xc7vx485t" SYNTHGUI_VERSION=0.2.0 scripts/package-linux.sh
#
# The folder has the layout the checkout has beside build/, because synthgui resolves {root}, {prefix} and {builds}
# from the directory above its executable (Project::repoRoot):
#
#   bin/synthgui, bin/qt.conf          the GUI; qt.conf points Qt at plugins/ only
#   lib/                               the Qt it was built against (Ubuntu 24.04's own Qt is 6.4, too old)
#   plugins/platforms/                 xcb and offscreen (QT_QPA_PLATFORM=offscreen for headless batch runs)
#   build-deps/...                     verilator_bin, sta, openFPGALoader, nextpnr-himbaechel and the chip databases,
#                                      tileverilog, lvs_equiv, xc7frames2bit
#   deps/prjxray-db                    the families in FAMILIES (default artix7 virtex7)
#   xc7/, projects/, example.json
#   README-Linux.txt                   the apt packages the tools load, and the udev rule for programming
#
# Only Qt is bundled; the other libraries (Boost, Tcl, libusb, libftdi, the X11 ones Qt's xcb plugin loads) are
# Ubuntu 24.04's, installed with apt as README-Linux.txt says.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Linux ] || { echo "run this on Linux" >&2; exit 1; }
VER=${SYNTHGUI_VERSION:-$(sed -n 's/^set(SYNTHGUI_VERSION "\([^"]*\)".*/\1/p' CMakeLists.txt)}
FAMILIES=${FAMILIES:-artix7 virtex7}
CHIPDBS=${CHIPDBS:-xc7a50t xc7vx485t}
B=build-release
OUT=$B/synthgui-$VER-linux-x86_64
BD=build-deps

cmake -S . -B $B/build -DCMAKE_BUILD_TYPE=Release -DSYNTHGUI_VERSION="$VER" >/dev/null
cmake --build $B/build --parallel "${JOBS:-$(nproc)}"

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/plugins/platforms"
copy() {  # copy SRC DST, creating DST's directory
    [ -e "$1" ] || { echo "missing: $1 (scripts/build-deps.sh builds it)" >&2; exit 1; }
    mkdir -p "$(dirname "$2")"
    cp -R "$1" "$2"
}

# ---- synthgui and Qt: the Qt libraries it and the two platform plugins load go to lib/
cp $B/build/synthgui "$OUT/bin/"
QTPLUGINS=$(qtpaths6 --query QT_INSTALL_PLUGINS)
cp "$QTPLUGINS"/platforms/{libqxcb,libqoffscreen}.so "$OUT/plugins/platforms/"
printf '[Paths]\nPrefix = ..\nPlugins = plugins\n' > "$OUT/bin/qt.conf"
qtlibs() { ldd "$@" | sed -n 's|.* => \(/[^ ]*libQt6[^ ]*\) .*|\1|p' | sort -u; }
for l in $(qtlibs "$OUT/bin/synthgui" "$OUT"/plugins/platforms/*.so); do cp -L "$l" "$OUT/lib/"; done
patchelf --set-rpath '$ORIGIN/../lib' "$OUT/bin/synthgui"
patchelf --set-rpath '$ORIGIN/../../lib' "$OUT"/plugins/platforms/*.so
for l in "$OUT"/lib/*.so*; do patchelf --set-rpath '$ORIGIN' "$l"; done

# ---- the tools with their own maintainers, as separate executables
for b in verilator_bin sta openFPGALoader; do copy $BD/prefix/bin/$b "$OUT/$BD/prefix/bin/$b"; done
copy $BD/prefix/share/verilator "$OUT/$BD/prefix/share/verilator"
copy $BD/prefix/share/openFPGALoader "$OUT/$BD/prefix/share/openFPGALoader"
rm -rf "$OUT/$BD/prefix/share/verilator/examples"
copy $BD/nextpnr/nextpnr-himbaechel "$OUT/$BD/nextpnr/nextpnr-himbaechel"
for d in $CHIPDBS; do
    copy $BD/nextpnr/share/himbaechel/xilinx/chipdb-$d.bin "$OUT/$BD/nextpnr/share/himbaechel/xilinx/chipdb-$d.bin"
done
for b in tileverilog lvs_equiv; do copy $BD/fasm2netlist/$b "$OUT/$BD/fasm2netlist/$b"; done
copy $BD/prjxray/tools/xc7frames2bit "$OUT/$BD/prjxray/tools/xc7frames2bit"
copy deps/openFPGALoader/99-openfpgaloader.rules "$OUT/99-openfpgaloader.rules"

# ---- the database the tools read; the example projects without the Sonata Linux tree
for fam in $FAMILIES; do
    mkdir -p "$OUT/deps/prjxray-db"
    cp -R deps/prjxray-db/$fam "$OUT/deps/prjxray-db/"
    rm -rf "$OUT/deps/prjxray-db/$fam/harness"
done
cp -R xc7 "$OUT/"
rm -rf "$OUT"/xc7/__pycache__ "$OUT"/xc7/*.py   # the reference the built-in tools (tools/) were checked against
mkdir -p "$OUT/projects"
tar -C projects --exclude linux --exclude '*.log' --exclude '*.bin' -cf - . | tar -C "$OUT/projects" -xf -
cp example.json "$OUT/"
cp scripts/README-Linux.txt "$OUT/"
# the icon and a menu entry: bin/synthgui runs without them, install-desktop.sh puts them in the user's menu
mkdir -p "$OUT/share/icons"
cp assets/icon/synthgui-{16,24,32,48,64,128,256,512}.png "$OUT/share/icons/"
cp assets/synthgui.desktop "$OUT/share/"
cp assets/install-desktop.sh "$OUT/"
# no debug information in the shipped programs
strip --strip-debug "$OUT"/bin/synthgui "$OUT"/lib/*.so* "$OUT/$BD"/nextpnr/nextpnr-himbaechel \
    "$OUT/$BD"/fasm2netlist/* "$OUT/$BD"/prjxray/tools/* "$OUT/$BD"/prefix/bin/{verilator_bin,sta,openFPGALoader}

# ---- Qt must come from lib/, nothing from build-deps/ or a home directory, and nothing may be missing
bad=0
for exe in "$OUT/bin/synthgui" "$OUT"/plugins/platforms/*.so "$OUT/$BD/prefix/bin/"* "$OUT/$BD/nextpnr/nextpnr-himbaechel" \
           "$OUT/$BD/fasm2netlist/"* "$OUT/$BD/prjxray/tools/"*; do
    deps=$(ldd "$exe" | grep -v " => $PWD/$OUT/")
    if echo "$deps" | grep "not found\|libQt6\|$HOME" >&2; then
        echo "  ^ in $exe" >&2
        bad=1
    fi
done
echo "$OUT: $(du -sm "$OUT" | cut -f1) MB"
[ $bad = 0 ] || exit 1

# ---- the tarball a release carries, and its SHA-256 for the release notes
TGZ=$OUT.tar.gz
rm -f "$TGZ"
tar -C "$B" -czf "$TGZ" "$(basename "$OUT")"
echo "$TGZ: $(du -sm "$TGZ" | cut -f1) MB"
echo "SHA-256: $(sha256sum "$TGZ" | cut -d' ' -f1)"
