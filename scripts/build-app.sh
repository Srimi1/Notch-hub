#!/usr/bin/env bash
#
# Builds NotchHub and assembles it into a proper .app bundle.
# Usage: ./scripts/build-app.sh [debug|release]   (default: release)
#
# Signing
# -------
# Signing identity, in order of preference:
#
#   1. NOTCHHUB_SIGNING_IDENTITY, if exported — use exactly that.
#   2. Auto-detected: the first "Apple Development" or "Developer ID
#      Application" identity in the login keychain. A stable identity is what
#      makes macOS privacy grants (Calendar, Reminders, Apple Events) survive
#      rebuilds — an ad-hoc signature changes every build, so TCC treats each
#      build as a brand-new app and prompts again.
#   3. Ad-hoc, when no identity exists. Runs locally; grants reset per rebuild;
#      Gatekeeper refuses it on other Macs.
#
# Identity-signed builds use the hardened runtime, a secure timestamp, and
# Resources/NotchHub.entitlements (Apple Events — required or Media/Focus
# break silently under the hardened runtime). Note: Apple Development
# certificates expire yearly; on expiry auto-detection finds nothing and the
# script falls back to ad-hoc with a warning rather than failing.
#
#   export NOTCHHUB_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   ./scripts/build-app.sh release       # then build-dmg.sh can notarize + staple
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/NotchHub.app"
SIGNING_IDENTITY="${NOTCHHUB_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  # Prefer a stable identity so TCC grants persist across rebuilds (see header).
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
ENTITLEMENTS="${NOTCHHUB_ENTITLEMENTS:-Resources/NotchHub.entitlements}"
TMP_DIR="$(mktemp -d)"
TMP_APP="$TMP_DIR/NotchHub.app"
trap 'rm -rf "$TMP_DIR"' EXIT

cleanup_legacy_apps() {
  while IFS= read -r -d '' legacy_app; do
    legacy_name="$(basename "$legacy_app")"
    if [[ "$legacy_name" =~ ^NotchHub\ [0-9]+\.app$ ]]; then
      echo "▸ Removing legacy bundle ${legacy_name}…"
      rm -rf -- "$legacy_app"
    fi
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name 'NotchHub *.app' -print0)
}

validate_publish_target() {
  if [[ -L "$APP" ]]; then
    echo "error: Refusing to replace a symlinked app bundle: $APP" >&2
    exit 1
  fi
  if [[ -e "$APP" && ! -d "$APP" ]]; then
    echo "error: App output exists but is not a directory: $APP" >&2
    exit 1
  fi
  if [[ -L "$APP/Contents" ]]; then
    echo "error: Refusing to replace a symlinked Contents directory: $APP/Contents" >&2
    exit 1
  fi
}

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

sign_bundle() {
  local -r target="$1"
  xattr -cr "$target" 2>/dev/null || true

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "▸ Ad-hoc code-signing (NOT distributable — Gatekeeper will block it)…"
    codesign --force --deep --sign - "$target"
    xattr -cr "$target" 2>/dev/null || true
    codesign --verify --deep --strict "$target"
    return 0
  fi

  echo "▸ Code-signing with \"$SIGNING_IDENTITY\" + hardened runtime…"
  local -a args=(--force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY")
  if [[ -n "$ENTITLEMENTS" ]]; then
    local entitlements_path="$ENTITLEMENTS"
    [[ "$entitlements_path" == /* ]] || entitlements_path="$ROOT/$entitlements_path"
    [[ -f "$entitlements_path" ]] || {
      echo "error: Entitlements file not found: $entitlements_path" >&2
      exit 1
    }
    args+=(--entitlements "$entitlements_path")
  fi
  codesign "${args[@]}" "$target"
  xattr -cr "$target" 2>/dev/null || true
  codesign --verify --deep --strict --verbose=2 "$target"
}

# Keep the canonical bundle directory stable so iCloud/Finder does not preserve
# successive builds as "NotchHub 2.app", "NotchHub 3.app", and so on.
validate_publish_target
mkdir -p "$APP"
rm -rf "$APP/Contents"
ditto "$TMP_APP/Contents" "$APP/Contents"
xattr -cr "$APP" 2>/dev/null || true
sign_bundle "$APP"
cleanup_legacy_apps

echo "✓ Built $APP"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "  Signing: ad-hoc — safe to run here, NOT safe to distribute."
  echo "           Privacy grants (Calendar/Reminders/Apple Events) reset on"
  echo "           every rebuild. Install an Apple Development certificate or"
  echo "           set NOTCHHUB_SIGNING_IDENTITY to make them stick."
else
  echo "  Signing: $SIGNING_IDENTITY (hardened runtime, timestamped)."
fi
echo "  Run with:  open \"$APP\"    (or  ./scripts/build-app.sh && open NotchHub.app )"
