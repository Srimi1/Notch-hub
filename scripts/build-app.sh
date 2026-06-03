#!/usr/bin/env bash
#
# Builds NotchHub and assembles it into a proper .app bundle.
# Usage: ./scripts/build-app.sh [debug|release]   (default: release)
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/NotchHub.app"
TMP_DIR="$(mktemp -d)"
TMP_APP="$TMP_DIR/NotchHub.app"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "▸ Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchHub"

echo "▸ Assembling ${APP}…"
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Resources"
cp "$BIN" "$TMP_APP/Contents/MacOS/NotchHub"
cp "$ROOT/Resources/Info.plist" "$TMP_APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$TMP_APP/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$TMP_APP"

echo "▸ Ad-hoc code-signing…"
codesign --force --deep --sign - "$TMP_APP"
codesign --verify --deep --strict "$TMP_APP"

rm -rf "$APP"
ditto "$TMP_APP" "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"
echo "  Run with:  open \"$APP\"    (or  ./scripts/build-app.sh && open NotchHub.app )"
