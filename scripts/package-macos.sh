#!/bin/bash
# Build synthgui.app, bundle Qt with macdeployqt, sign it (hardened runtime) with a Developer ID Application identity
# and make a zip; optionally notarize. Output goes to build-release/.
#
#   scripts/package-macos.sh                      sign with the first "Developer ID Application" identity found
#   SIGN_ID="Developer ID Application: ..." scripts/package-macos.sh
#   NOTARY_PROFILE=name scripts/package-macos.sh  also notarize and staple (profile made once with
#                                                 `xcrun notarytool store-credentials name`)
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=... scripts/package-macos.sh
#                                                 the same with an App Store Connect API key, as CI has no keychain profile
#   SYNTHGUI_VERSION=0.2.0 scripts/package-macos.sh
#
# The tools the flow runs (verilator, nextpnr, prjxray, openFPGALoader, sta, Python and their libraries) go into
# Contents/Resources/{build-deps,deps}, laid out as the checkout has them beside build/ (scripts/bundle-tools.py).
# No Python is needed or shipped.
set -euo pipefail
cd "$(dirname "$0")/.."
QT=${QT_PREFIX:-/opt/homebrew/opt/qt}
VER=${SYNTHGUI_VERSION:-$(sed -n 's/^set(SYNTHGUI_VERSION "\([^"]*\)".*/\1/p' CMakeLists.txt)}
B=build-release
APP=$B/synthgui.app
ID=${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$ID" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
echo "signing as: $ID"

rm -rf "$APP"   # macdeployqt rewrites the executable in place, so always start from a freshly linked bundle
cmake -S . -B $B -DSYNTHGUI_BUNDLE=ON -DSYNTHGUI_VERSION="$VER" -DCMAKE_PREFIX_PATH="$QT" >/dev/null
cmake --build $B -j"$(sysctl -n hw.ncpu)"
"$QT/bin/macdeployqt" "$APP" >/dev/null
# macdeployqt only ships the cocoa platform; add offscreen for headless batch runs (QT_QPA_PLATFORM=offscreen)
OFF=$("$QT/bin/qtpaths" --plugin-dir)/platforms/libqoffscreen.dylib
[ -n "$OFF" ] && cp "$OFF" "$APP/Contents/PlugIns/platforms/"

R=$APP/Contents/Resources
mkdir -p $R
cp -R xc7 $R/
rm -rf $R/xc7/__pycache__ $R/xc7/*.py     # the .py files are the reference the built-in tools (tools/) were checked against
# the example projects and their sources, without the Sonata Linux tree (116 MB; its sources for synthesis are rtl/ and the .v files)
mkdir -p $R/projects && rsync -a --exclude linux --exclude '*.log' projects/ $R/projects/ && cp example.json $R/
# the tools with their own maintainers (verilator, nextpnr, OpenSTA, prjxray, openFPGALoader, fasm2netlist) as separate
# executables with their libraries, relocated into the bundle. The converters (tools/) are inside synthgui itself.
python3 scripts/bundle-tools.py "$R"

# sign inside-out: every Mach-O file first, then the bundle
find "$APP" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    file -b "$f" | grep -q 'Mach-O' && codesign --force --timestamp --options runtime -s "$ID" "$f"
done
find "$APP" -name '*.framework' -maxdepth 4 | while read -r f; do codesign --force --timestamp --options runtime -s "$ID" "$f"; done
codesign --force --timestamp --options runtime -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP=$B/synthgui-$VER-macos-arm64.zip
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
auth=()
if [ -n "${NOTARY_KEY:-}" ]; then auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_PROFILE:-}" ]; then auth=(--keychain-profile "$NOTARY_PROFILE"); fi
if [ ${#auth[@]} -gt 0 ]; then
    xcrun notarytool submit "$ZIP" "${auth[@]}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "not notarized: set NOTARY_PROFILE (or NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER) to submit and staple (spctl will say 'Unnotarized Developer ID' until then)"
fi
echo "$ZIP"
