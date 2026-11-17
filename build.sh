#!/bin/bash
set -euo pipefail

APP_NAME="ClipboardHistory"
APP_BUNDLE="$APP_NAME.app"

cd "$(dirname "$0")"

echo "→ Building $APP_NAME (release)..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [ ! -f "$BIN" ]; then
    echo "✗ Binary not found at $BIN"
    exit 1
fi

echo "→ Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# ── Code-signing ────────────────────────────────────────────────────────────
# macOS ties the Accessibility (CGEventTap) grant to the app's code identity.
# An UNSIGNED binary gets a new identity on every rebuild, so the permission
# silently resets and capture dies. Signing with a STABLE self-signed identity
# keeps the grant across rebuilds. If that identity is missing we fall back to
# an ad-hoc signature and warn (you'll have to re-grant after each rebuild).
#
# Create the stable identity once:  ./scripts/create-signing-cert.sh
SIGN_IDENTITY="${CLIPBOARD_SIGN_IDENTITY:-ClipboardHistory Self-Signed}"
BUNDLE_ID="com.tomkoo.ClipboardHistory"

echo "→ Code-signing..."
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "  Using stable identity '$SIGN_IDENTITY'."
    codesign --force --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "  ⚠ Identity '$SIGN_IDENTITY' not found — using an ad-hoc signature."
    echo "    Accessibility permission will reset on each rebuild."
    echo "    Fix permanently: ./scripts/create-signing-cert.sh"
    codesign --force --identifier "$BUNDLE_ID" --sign - "$APP_BUNDLE"
fi
codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /' || true

echo "✓ Built $APP_BUNDLE"
echo ""
echo "Launch:  open $APP_BUNDLE"
echo "Install: mv $APP_BUNDLE /Applications/"
