#!/bin/bash
# approve-release.sh <tag> [--publish] [--dry-run] [--sign 'glob ...']
# The approval of a draft release made by .github/workflows/release.yml: check what the workflow built,
# sign the Windows program, and (with --publish) publish.
#
#   1. the release must be a draft; its archives are downloaded and checked against its SHA256SUMS
#   2. in the Windows zip, bin/synthgui.exe (and whatever --sign adds, e.g. 'build-deps/fasm2netlist/*.exe')
#      is signed with scripts/sign-windows.sh: SimplySign Desktop must be logged in. Every other entry of
#      the zip is carried over byte for byte.
#   3. SHA256SUMS and the sums in the release notes are rewritten, and the zip and SHA256SUMS replace the
#      draft's (not with --dry-run, which leaves the results in the work directory and GitHub untouched)
#   4. --publish then makes the draft public. Without it the draft stays a draft, to look at first.
#
# A program that is already signed is left as it is, so the script can be run again.
# Needs gh (logged in, with write access), python3, and what sign-windows.sh needs (SIGN_ROOT, SIMPLYSIGN_MODULE).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tag=; publish=0; dry=0; extra=
while [ $# -gt 0 ]; do
  case $1 in --publish) publish=1;; --dry-run) dry=1;; --sign) extra=$2; shift;; -*) echo "unknown option $1" >&2; exit 2;; *) tag=$1;; esac
  shift
done
[ -n "$tag" ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
repo=${REPO:-jrrk2/synthgui}
w=${WORK:-$(mktemp -d)}; mkdir -p "$w"; cd "$w"
[ "$(gh release view "$tag" -R "$repo" --json isDraft --jq .isDraft)" = true ] || { echo "$tag is not a draft release: nothing to approve" >&2; exit 1; }
rm -rf assets; mkdir assets
gh release download "$tag" -R "$repo" -D assets
(cd assets && sha256sum -c SHA256SUMS) || { echo "the draft's archives do not match its SHA256SUMS" >&2; exit 1; }
zip=$(ls assets/*windows*.zip 2>/dev/null | head -1)
[ -n "$zip" ] || { echo "no Windows zip in $tag" >&2; exit 1; }

# the programs to sign, out of the zip
python3 - "$zip" "$w/sign" "bin/synthgui.exe $extra" <<'PY'
import fnmatch, os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); out = sys.argv[2]; pats = sys.argv[3].split()
os.makedirs(out, exist_ok=True)
n = 0
for i in z.infolist():
    rel = i.filename.split('/', 1)[1] if '/' in i.filename else i.filename
    if any(fnmatch.fnmatch(rel, p) for p in pats) and not i.is_dir():
        p = os.path.join(out, i.filename); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'wb').write(z.read(i)); n += 1
        print(i.filename)
if not n: sys.exit('nothing in the zip matches ' + ' '.join(pats))
PY
find sign -type f -name '*.exe' | sort > tosign.txt
while read -r f; do
  if SIGN_CHECK=1 "$here/sign-windows.sh" --is-signed "$f" 2>/dev/null; then echo "already signed: ${f#sign/}"; continue; fi
  "$here/sign-windows.sh" "$f" "$f.signed"
  mv "$f.signed" "$f"
done < tosign.txt

# the zip again: every entry as it was, the signed programs in place of the unsigned ones
python3 - "$zip" "$w/sign" "$w/signed.zip" <<'PY'
import os, sys, zipfile
src = zipfile.ZipFile(sys.argv[1]); root = sys.argv[2]
with zipfile.ZipFile(sys.argv[3], 'w') as dst:
    for i in src.infolist():
        data = src.read(i)
        p = os.path.join(root, i.filename)
        if os.path.isfile(p):
            new = open(p, 'rb').read()
            if new != data: print('replaced', i.filename, len(data), '->', len(new))
            data = new
        dst.writestr(i, data, compress_type=i.compress_type)
PY
mv signed.zip "$zip"
(cd assets && sha256sum $(ls | grep -v '^SHA256SUMS$') > SHA256SUMS && cat SHA256SUMS)
gh release view "$tag" -R "$repo" --json body --jq .body > notes.old
python3 - notes.old assets/SHA256SUMS notes.new "$(cat tosign.txt | sed 's#^sign/[^/]*/##' | tr '\n' ' ')" <<'PY'
import re, sys
body = open(sys.argv[1]).read(); sums = open(sys.argv[2]).read().strip(); what = sys.argv[4].split()
body, n = re.subn(r'(SHA-256:\s*```\s*\n).*?(\n```)', lambda m: m.group(1) + sums + m.group(2), body, flags=re.S)
if not n: body += '\n\nSHA-256:\n```\n' + sums + '\n```\n'
line = 'Windows: ' + ', '.join(what) + ' signed (Authenticode, Certum Open Source Code Signing, "Open Source Developer Jonathan Kimmitt"); the tools bundled from other projects are not signed.'
body = re.sub(r'\n*Windows: .* signed \(Authenticode.*\n?', '\n', body).rstrip() + '\n\n' + line + '\n'
open(sys.argv[3], 'w').write(body)
PY
if [ $dry = 1 ]; then echo "dry run: the signed zip, SHA256SUMS and notes.new are in $w; nothing uploaded"; exit 0; fi
gh release upload "$tag" -R "$repo" "$zip" assets/SHA256SUMS --clobber
gh release edit "$tag" -R "$repo" --notes-file notes.new
echo "draft $tag updated"
if [ $publish = 1 ]; then gh release edit "$tag" -R "$repo" --draft=false && echo "$tag published"
else echo "still a draft: look it over, then run again with --publish"; fi
