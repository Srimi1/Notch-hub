#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDITION="${1:-direct}"
CONFIGURATION="${2:-release}"
SIGNING_IDENTITY="${NOTCHHUB_SIGNING_IDENTITY:-}"
TEAM_IDENTIFIER="${NOTCHHUB_TEAM_ID:-}"
UNIVERSAL="${NOTCHHUB_UNIVERSAL:-1}"
OFFICIAL_RELEASE="${NOTCHHUB_OFFICIAL_RELEASE:-0}"

case "$EDITION" in
  direct)
    PRODUCT="NotchHubV1"
    if [[ "$OFFICIAL_RELEASE" == "1" ]]; then
      APP_NAME="NotchHub"
    else
      APP_NAME="NotchHub V1 Preview"
    fi
    INFO_PLIST="$ROOT/Resources/Direct/Info.plist"
    ENTITLEMENTS_TEMPLATE="$ROOT/Resources/Direct/NotchHubV1.entitlements"
    HELPER_ENTITLEMENTS_TEMPLATE="$ROOT/Resources/Direct/NotchHubHookBridge.entitlements"
    ;;
  lite)
    PRODUCT="NotchHubLite"
    APP_NAME="NotchHub Lite"
    INFO_PLIST="$ROOT/Resources/Lite/Info.plist"
    ENTITLEMENTS_TEMPLATE="$ROOT/Resources/Lite/NotchHubLite.entitlements"
    HELPER_ENTITLEMENTS_TEMPLATE=""
    ;;
  *)
    echo "usage: $0 [direct|lite] [debug|release]" >&2
    exit 64
    ;;
esac

OUTPUT_DIR="${NOTCHHUB_OUTPUT_DIR:-$ROOT}"
if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" != /* || "$OUTPUT_DIR" == "/" || -L "$OUTPUT_DIR" ]]; then
  echo "NOTCHHUB_OUTPUT_DIR must be an absolute, non-symlinked directory" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/$APP_NAME.app"
TEMP_DIR="$(mktemp -d /tmp/notchhub-v1-build.XXXXXX)"
TEMP_APP="$TEMP_DIR/$APP_NAME.app"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

resolve_team_identifier() {
  if [[ -n "$TEAM_IDENTIFIER" ]]; then
    return
  fi
  if [[ "$SIGNING_IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
    TEAM_IDENTIFIER="${BASH_REMATCH[1]}"
  fi
}

prepare_entitlements() {
  local template="$1"
  local destination="$2"
  cp "$template" "$destination"
  if [[ "$EDITION" == "direct" ]]; then
    resolve_team_identifier
    if [[ ! "$TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]]; then
      echo "direct signing requires NOTCHHUB_TEAM_ID or an identity ending in a 10-character Team ID" >&2
      exit 1
    fi
    /usr/libexec/PlistBuddy \
      -c "Set :keychain-access-groups:0 $TEAM_IDENTIFIER.com.notchhub.v1.bridge" \
      "$destination"
  fi
}

build_path() {
  local arch="$1"
  swift build -c "$CONFIGURATION" --arch "$arch" --product "$PRODUCT" >&2
  swift build -c "$CONFIGURATION" --arch "$arch" --show-bin-path
}

make_binary() {
  local product="$1"
  local destination="$2"
  if [[ "$CONFIGURATION" == "release" && "$UNIVERSAL" == "1" ]]; then
    local arm_path intel_path
    arm_path="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)/$product"
    intel_path="$(swift build -c "$CONFIGURATION" --arch x86_64 --show-bin-path)/$product"
    swift build -c "$CONFIGURATION" --arch arm64 --product "$product"
    swift build -c "$CONFIGURATION" --arch x86_64 --product "$product"
    lipo -create "$arm_path" "$intel_path" -output "$destination"
  else
    swift build -c "$CONFIGURATION" --product "$product"
    local bin_path
    bin_path="$(swift build -c "$CONFIGURATION" --show-bin-path)/$product"
    cp "$bin_path" "$destination"
  fi
}

ensure_framework_runtime_path() {
  local binary="$1"
  local framework_path='@executable_path/../Frameworks'
  if otool -l "$binary" | grep -F "$framework_path" >/dev/null; then
    return
  fi
  install_name_tool -add_rpath "$framework_path" "$binary"
}

if [[ -L "$OUTPUT" || -L "$OUTPUT/Contents" ]]; then
  echo "refusing to replace symlinked output: $OUTPUT" >&2
  exit 1
fi

mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources"
cp "$INFO_PLIST" "$TEMP_APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$TEMP_APP/Contents/Resources/"
make_binary "$PRODUCT" "$TEMP_APP/Contents/MacOS/$PRODUCT"

if [[ "$EDITION" == "direct" ]]; then
  mkdir -p "$TEMP_APP/Contents/Resources/ThirdParty"
  cp "$ROOT/Resources/ThirdParty/Sparkle-LICENSE.txt" "$TEMP_APP/Contents/Resources/ThirdParty/"
  UPDATE_FEED_URL="${NOTCHHUB_UPDATE_FEED_URL:-}"
  UPDATE_PUBLIC_KEY="${NOTCHHUB_UPDATE_PUBLIC_KEY:-}"
  if [[ "${NOTCHHUB_RELEASE:-0}" == "1" && ( -z "$UPDATE_FEED_URL" || -z "$UPDATE_PUBLIC_KEY" ) ]]; then
    echo "release builds require NOTCHHUB_UPDATE_FEED_URL and NOTCHHUB_UPDATE_PUBLIC_KEY" >&2
    exit 1
  fi
  if [[ "${NOTCHHUB_RELEASE:-0}" == "1" && -z "$SIGNING_IDENTITY" ]]; then
    echo "release builds require NOTCHHUB_SIGNING_IDENTITY" >&2
    exit 1
  fi
  if [[ "$OFFICIAL_RELEASE" == "1" ]]; then
    if [[ "$CONFIGURATION" != "release" || "${NOTCHHUB_RELEASE:-0}" != "1" ]]; then
      echo "official builds require release configuration and NOTCHHUB_RELEASE=1" >&2
      exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.notchhub.app" "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName NotchHub" "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NOTCHHUB_VERSION:-1.0.0}" \
      "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NOTCHHUB_BUILD:-1000}" \
      "$TEMP_APP/Contents/Info.plist"
  fi
  if [[ -n "$UPDATE_FEED_URL" && -n "$UPDATE_PUBLIC_KEY" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $UPDATE_FEED_URL" "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $UPDATE_PUBLIC_KEY" "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$TEMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool true" "$TEMP_APP/Contents/Info.plist"
  fi
  mkdir -p "$TEMP_APP/Contents/Helpers"
  make_binary "NotchHubHookBridge" "$TEMP_APP/Contents/Helpers/NotchHubHookBridge"

  SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not produced by SwiftPM" >&2
    exit 1
  fi
  mkdir -p "$TEMP_APP/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK" "$TEMP_APP/Contents/Frameworks/Sparkle.framework"
  ensure_framework_runtime_path "$TEMP_APP/Contents/MacOS/$PRODUCT"
fi

xattr -cr "$TEMP_APP"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  APP_ENTITLEMENTS="$TEMP_DIR/app.entitlements"
  prepare_entitlements "$ENTITLEMENTS_TEMPLATE" "$APP_ENTITLEMENTS"
  if [[ "$EDITION" == "direct" ]]; then
    HELPER_ENTITLEMENTS="$TEMP_DIR/helper.entitlements"
    prepare_entitlements "$HELPER_ENTITLEMENTS_TEMPLATE" "$HELPER_ENTITLEMENTS"
    codesign --force --options runtime --timestamp \
      --identifier "com.notchhub.v1.bridge.helper" \
      --entitlements "$HELPER_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" \
      "$TEMP_APP/Contents/Helpers/NotchHubHookBridge"
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
      "$TEMP_APP/Contents/Frameworks/Sparkle.framework"
  fi
  sign_args=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$APP_ENTITLEMENTS")
  codesign "${sign_args[@]}" "$TEMP_APP"
else
  if [[ "$EDITION" == "lite" ]]; then
    APP_ENTITLEMENTS="$TEMP_DIR/app.entitlements"
    prepare_entitlements "$ENTITLEMENTS_TEMPLATE" "$APP_ENTITLEMENTS"
    codesign --force --deep --sign - --entitlements "$APP_ENTITLEMENTS" "$TEMP_APP"
  else
    codesign --force --deep --sign - "$TEMP_APP"
  fi
fi
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"

mkdir -p "$OUTPUT"
rm -rf -- "$OUTPUT/Contents"
ditto "$TEMP_APP/Contents" "$OUTPUT/Contents"
xattr -cr "$OUTPUT"
codesign --verify --deep --strict --verbose=2 "$OUTPUT"
echo "✓ Built $OUTPUT"
