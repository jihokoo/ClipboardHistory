#!/bin/bash
# Creates a stable, self-signed code-signing identity in your login keychain.
#
# Why: macOS ties the Accessibility (CGEventTap) permission to an app's code
# identity. An unsigned app gets a brand-new identity every rebuild, so the
# grant silently resets and clipboard capture stops. Signing every build with
# ONE persistent certificate keeps the grant across rebuilds — you grant
# Accessibility once and never again.
#
# Run this ONCE. build.sh then picks the identity up automatically.
# You may be asked to allow "codesign" to use the key the first time it signs.

set -euo pipefail

IDENTITY="${CLIPBOARD_SIGN_IDENTITY:-ClipboardHistory Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Signing identity '$IDENTITY' already exists. Nothing to do."
    exit 0
fi

echo "→ Creating self-signed code-signing certificate '$IDENTITY'..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# OpenSSL 3 (Homebrew) defaults to a PKCS#12 MAC that macOS's importer rejects
# with "MAC verification failed". Export in -legacy format (when supported) and
# with a non-empty transient password so `security import` can read it.
P12_PASS="clipboardhistory"
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    LEGACY="-legacy"
fi

openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

# Import key + cert, and pre-authorize codesign to use the key without prompts.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Trust it for code signing in the login keychain (may prompt for your keychain
# password). Not strictly required for codesign to seal the bundle, but makes
# `security find-identity -p codesigning` list it as valid.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
    echo "  (could not set trust automatically — codesign will still work)"

echo "✓ Created '$IDENTITY'. Now run ./build.sh and it will sign with it."
