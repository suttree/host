#!/bin/bash
# Create a stable self-signed code signing identity for local development.
#
# Why this exists: macOS keys Accessibility (TCC) grants to an app's code
# signature. An ad-hoc signature ("codesign -s -") changes on every build, so
# every rebuild silently invalidates the grant -- the app still appears ticked in
# System Settings, but window calls start failing. A self-signed certificate
# gives a signature that is stable across rebuilds, so you grant once.
#
# Everything lives in a dedicated keychain. Nothing touches your login keychain
# and nothing needs sudo.
set -euo pipefail

NAME="Host Dev"
KEYCHAIN="$HOME/Library/Keychains/host.keychain-db"
KEYCHAIN_SHORT="host.keychain"
PASSWORD="host"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "identity '$NAME' already exists -- nothing to do."
  exit 0
fi

cat > "$WORK/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

# Apple's Security framework cannot read the AES-256/SHA-256 PKCS#12 that
# OpenSSL 3 writes by default ("MAC verification failed" on import). macOS ships
# LibreSSL at /usr/bin/openssl, which still writes the old format, so pin to it
# rather than whatever a Homebrew openssl on PATH happens to be.
SSL=/usr/bin/openssl

echo "generating certificate..."
"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
"$SSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD" -name "$NAME"

if [ ! -f "$KEYCHAIN" ]; then
  echo "creating keychain $KEYCHAIN_SHORT..."
  security create-keychain -p "$PASSWORD" "$KEYCHAIN_SHORT"
fi
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no lock timeout

echo "importing..."
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

# Without this codesign triggers a GUI "allow access to key?" prompt on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# Put the keychain on the search list so codesign can find the identity by name.
EXISTING=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
if ! echo "$EXISTING" | grep -q "host"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo
echo "done. identity: $NAME"
echo "next: make run, then grant Accessibility once. Rebuilds will keep the grant."
