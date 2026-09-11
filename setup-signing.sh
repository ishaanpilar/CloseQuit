#!/bin/bash
# Creates a self-signed code-signing identity named "CloseQuit Local".
#
# Why this exists: macOS binds an Accessibility grant to the app's *designated
# requirement*. Under an ad-hoc signature that requirement is the binary hash, so
# every rebuild revokes the permission and the daemon silently watches nothing.
# Signed with a certificate, the requirement becomes
#
#     identifier "com.ishaanpilar.CloseQuit" and certificate leaf = H"<cert hash>"
#
# which has no hash of the binary in it, so the grant survives rebuilds.
#
# macOS will ask you to authorise adding the certificate to your login keychain.
# To undo: delete "CloseQuit Local" in Keychain Access (login keychain, My
# Certificates), then rebuild — build.sh falls back to ad-hoc.
set -euo pipefail

NAME="CloseQuit Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "\"$NAME\" already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# The passphrase is a formality: the file exists for a few milliseconds inside a
# mktemp dir that this script deletes on exit. `security import` rejects an empty one.
openssl pkcs12 -export -out "$TMP/ident.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:closequit -name "$NAME"

security import "$TMP/ident.p12" -k "$KEYCHAIN" -P closequit -T /usr/bin/codesign -A

# Untrusted, the certificate imports fine but is not a *valid* signing identity
# (CSSMERR_TP_NOT_TRUSTED) and codesign will not use it.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME"
echo
echo "Done. ./build.sh will use it automatically."
echo "The Accessibility grant needs to be given once more after the next build,"
echo "because the signature changes — and then it will stick."
