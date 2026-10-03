#!/bin/zsh
# Creates a self-signed code-signing identity in the login keychain (one-time).
# A stable identity keeps macOS privacy grants (mic, Accessibility) across rebuilds.
set -euo pipefail

CN="${BABBLE_SIGN_IDENTITY:-Babble Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$CN' already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created identity '$CN'."
