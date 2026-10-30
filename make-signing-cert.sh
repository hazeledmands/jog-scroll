#!/bin/sh
# Creates a self-signed code-signing certificate in your login keychain, used by build.sh.
#
# Signing every build with the same certificate lets macOS recognise a rebuilt Jog Scroll
# as the same app, so its Accessibility permission survives rebuilds. (With ad-hoc signing,
# every build looks like a new app.) The certificate is only used on this Mac.
set -e

NAME="Jog Scroll Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in your login keychain."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)   # only protects the temporary .p12 between the two commands below

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS"

# -T lets codesign use the key without asking each time.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\" in your login keychain."
