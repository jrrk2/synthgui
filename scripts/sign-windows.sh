#!/bin/bash
# sign-windows.sh <in.exe> <out.exe> [description] [url]
# sign-windows.sh --is-signed <file.exe>
# Authenticode-sign a Windows program with the release certificate (Certum Open Source Code Signing,
# held in Certum's cloud and reached through SimplySign Desktop), on Linux.
#
# SimplySign Desktop must be running and logged in with the one-time code from the mobile app; it then
# presents the key through Certum's PKCS#11 module, and signs without a further PIN until it is logged
# out. SHA-256, timestamped by Certum (so the signature outlives the certificate), with the issuing
# CA's certificate embedded.
#
# Needs osslsigncode (2.6 or later), OpenSC's pkcs11-tool and OpenSSL's pkcs11 provider:
#   apt install osslsigncode opensc pkcs11-provider
# or, without root, the same packages unpacked (apt-get download, dpkg -x) under a directory named in
# SIGN_ROOT. osslsigncode's older pkcs11 *engine* crashes with Certum's module; the provider works.
# SIMPLYSIGN_MODULE names the module if it is not /usr/lib/libSimplySignPKCS.so.
set -eu
R=${SIGN_ROOT:-}
if [ -n "$R" ]; then
  export LD_LIBRARY_PATH=$R/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  PATH=$R/usr/bin:$PATH
fi
if [ "${1:-}" = --is-signed ]; then   # exit 0 if the file already carries a signature that verifies
  osslsigncode verify -in "$2" 2>/dev/null | grep -q "^Signature verification: ok"; exit $?
fi
in=$1; out=$2; desc=${3:-synthgui}; url=${4:-https://github.com/jrrk2/synthgui}
M=${SIMPLYSIGN_MODULE:-/usr/lib/libSimplySignPKCS.so}
if [ -n "$R" ]; then
  prov=$R/usr/lib/x86_64-linux-gnu/ossl-modules/pkcs11.so
else
  prov=$(openssl version -m 2>/dev/null | sed -n 's/^MODULESDIR: "\(.*\)"$/\1/p')/pkcs11.so
fi
for t in osslsigncode pkcs11-tool openssl curl; do command -v $t >/dev/null || { echo "sign-windows: $t not found" >&2; exit 2; }; done
[ -f "$prov" ] || { echo "sign-windows: OpenSSL's pkcs11 provider not found ($prov)" >&2; exit 2; }
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
id=$(pkcs11-tool --module "$M" -O --type cert 2>/dev/null | sed -n 's/^ *ID: *//p' | head -1)
[ -n "$id" ] || { echo "sign-windows: no certificate on the card: is SimplySign Desktop running and logged in?" >&2; exit 3; }
pkcs11-tool --module "$M" --read-object --type cert --id "$id" -o "$w/leaf.der" >/dev/null 2>&1
openssl x509 -inform der -in "$w/leaf.der" -out "$w/leaf.pem"
ca=$(openssl x509 -in "$w/leaf.pem" -noout -ext authorityInfoAccess | grep -o 'http[^ ]*\.\(cer\|crt\)' | head -1)
curl -fsSL "$ca" -o "$w/int.bin"
openssl x509 -inform der -in "$w/int.bin" -out "$w/int.pem" 2>/dev/null || openssl x509 -in "$w/int.bin" -out "$w/int.pem"
openssl verify -untrusted "$w/int.pem" "$w/leaf.pem" >/dev/null
cat "$w/leaf.pem" "$w/int.pem" > "$w/certs.pem"
rm -f "$out"
PKCS11_PROVIDER_MODULE=$M osslsigncode sign -provider "$prov" -pkcs11module "$M" -certs "$w/certs.pem" \
    -key "pkcs11:id=$(echo "$id" | sed 's/../%&/g');type=private" -h sha256 -n "$desc" -i "$url" \
    -ts http://time.certum.pl -in "$in" -out "$out" < /dev/null > "$w/sign.log" 2>&1 || { cat "$w/sign.log" >&2; exit 1; }
# the result must verify, chain and timestamp included
osslsigncode verify -in "$out" > "$w/verify.log" 2>&1 || { tail -5 "$w/verify.log" >&2; exit 1; }
grep -q "^Signature verification: ok" "$w/verify.log" || { tail -5 "$w/verify.log" >&2; exit 1; }
echo "signed $(basename "$in"): $(openssl x509 -in "$w/leaf.pem" -noout -subject | sed 's/^subject=//'), timestamp $(sed -n 's/^\tTimestamp time: //p' "$w/verify.log" | head -1)"
