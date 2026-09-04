#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$ROOT/.." && pwd)"
cd "$ROOT"
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

ASTRONAUT_ANIMATION_SOURCE="$REPOSITORY_ROOT/Resources/Animations/astronaut-and-music.json"
MEDIA_ADAPTER_SCRIPT_SOURCE="$REPOSITORY_ROOT/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"
MEDIA_ADAPTER_BUILD_SCRIPT="$REPOSITORY_ROOT/scripts/build-adapter.sh"
LOTTIE_LICENSE_SOURCE="$ROOT/Resources/ThirdParty/Lottie-LICENSE.txt"
LOTTIE_PRIVACY_MANIFEST_SOURCE="$ROOT/Resources/ThirdParty/Lottie-PrivacyInfo.xcprivacy"
LOTTIE_PRIVACY_MANIFEST_CHECKOUT="$ROOT/.build/checkouts/lottie-ios/Sources/PrivacyInfo.xcprivacy"
LOTTIE_PRIVACY_MANIFEST_SHA256="10da67f217824f019288ec328ababc290ab0399c52e9be77a24d494339137da2"

require_regular_source() {
  local source_path="$1"
  [[ -f "$source_path" && ! -L "$source_path" ]] || {
    echo "required bundle source is missing or symlinked: $source_path" >&2
    exit 1
  }
}

validate_lottie_privacy_manifest() {
  local manifest_path="$1"
  local actual_hash tracking api_type api_reason

  require_regular_source "$manifest_path"
  /usr/bin/plutil -lint "$manifest_path" >/dev/null
  actual_hash="$(/usr/bin/shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}')"
  [[ "$actual_hash" == "$LOTTIE_PRIVACY_MANIFEST_SHA256" ]] || {
    echo "Lottie privacy manifest does not match the pinned 4.6.1 manifest" >&2
    exit 1
  }
  tracking="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$manifest_path")"
  api_type="$(/usr/libexec/PlistBuddy -c \
    'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType' "$manifest_path")"
  api_reason="$(/usr/libexec/PlistBuddy -c \
    'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0' "$manifest_path")"
  [[ "$tracking" == "false" && \
    "$api_type" == "NSPrivacyAccessedAPICategoryFileTimestamp" && \
    "$api_reason" == "C617.1" ]] || {
    echo "Lottie privacy manifest is missing its required-reason declaration" >&2
    exit 1
  }
}

resolve_team_identifier() {
  local certificate_pem certificate_subject certificate_team_identifier
  if ! certificate_pem="$(security find-certificate -c "$SIGNING_IDENTITY" -p 2>/dev/null)" ||
    [[ -z "$certificate_pem" ]]; then
    echo "could not resolve the signing certificate for: $SIGNING_IDENTITY" >&2
    exit 1
  fi
  if ! certificate_subject="$(printf '%s\n' "$certificate_pem" |
    openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)"; then
    echo "could not inspect the signing certificate team identifier" >&2
    exit 1
  fi
  if [[ "$certificate_subject" =~ (^|,)OU=([A-Z0-9]{10})(,|$) ]]; then
    certificate_team_identifier="${BASH_REMATCH[2]}"
  else
    echo "signing certificate is missing a 10-character Apple Team ID" >&2
    exit 1
  fi
  if [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "$certificate_team_identifier" ]]; then
    echo "NOTCHHUB_TEAM_ID does not match the signing certificate Team ID" >&2
    exit 1
  fi
  TEAM_IDENTIFIER="$certificate_team_identifier"
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

prepare_ad_hoc_direct_entitlements() {
  local destination="$1"
  cp "$ENTITLEMENTS_TEMPLATE" "$destination"
  /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$destination"
  if [[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.automation.apple-events' "$destination")" != "true" ]]; then
    echo "ad-hoc Direct signing requires the Apple Events automation entitlement" >&2
    exit 1
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
make_binary "$PRODUCT" "$TEMP_APP/Contents/MacOS/$PRODUCT"

if [[ "$EDITION" == "direct" ]]; then
  require_regular_source "$ASTRONAUT_ANIMATION_SOURCE"
  require_regular_source "$MEDIA_ADAPTER_SCRIPT_SOURCE"
  require_regular_source "$MEDIA_ADAPTER_BUILD_SCRIPT"
  require_regular_source "$REPOSITORY_ROOT/Vendor/mediaremote-adapter/LICENSE"
  require_regular_source "$LOTTIE_LICENSE_SOURCE"
  validate_lottie_privacy_manifest "$LOTTIE_PRIVACY_MANIFEST_SOURCE"
  validate_lottie_privacy_manifest "$LOTTIE_PRIVACY_MANIFEST_CHECKOUT"
  cmp -s "$LOTTIE_PRIVACY_MANIFEST_CHECKOUT" "$LOTTIE_PRIVACY_MANIFEST_SOURCE" || {
    echo "checked-in Lottie privacy manifest differs from the pinned package checkout" >&2
    exit 1
  }
  require_regular_source "$ROOT/THIRD_PARTY_NOTICES.md"
  for notice in \
    Sparkle-LICENSE.txt \
    Lottie-NOTICE.txt \
    MediaRemoteAdapter-NOTICE.txt \
    Astronaut-and-Music-LICENSE.txt \
    Astronaut-and-Music-NOTICE.txt; do
    require_regular_source "$ROOT/Resources/ThirdParty/$notice"
  done

  mkdir -p \
    "$TEMP_APP/Contents/Frameworks" \
    "$TEMP_APP/Contents/Resources/Animations" \
    "$TEMP_APP/Contents/Resources/ThirdParty"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$TEMP_APP/Contents/Resources/"
  cp "$ROOT/Resources/ThirdParty/Sparkle-LICENSE.txt" \
    "$ROOT/Resources/ThirdParty/Lottie-NOTICE.txt" \
    "$ROOT/Resources/ThirdParty/MediaRemoteAdapter-NOTICE.txt" \
    "$ROOT/Resources/ThirdParty/Astronaut-and-Music-LICENSE.txt" \
    "$ROOT/Resources/ThirdParty/Astronaut-and-Music-NOTICE.txt" \
    "$TEMP_APP/Contents/Resources/ThirdParty/"
  cp "$LOTTIE_LICENSE_SOURCE" \
    "$TEMP_APP/Contents/Resources/ThirdParty/Lottie-LICENSE.txt"
  cp "$LOTTIE_PRIVACY_MANIFEST_SOURCE" \
    "$TEMP_APP/Contents/Resources/PrivacyInfo.xcprivacy"
  cmp -s "$LOTTIE_PRIVACY_MANIFEST_SOURCE" \
    "$TEMP_APP/Contents/Resources/PrivacyInfo.xcprivacy"
  cp "$REPOSITORY_ROOT/Vendor/mediaremote-adapter/LICENSE" \
    "$TEMP_APP/Contents/Resources/ThirdParty/MediaRemoteAdapter-LICENSE.txt"
  cp "$ASTRONAUT_ANIMATION_SOURCE" "$TEMP_APP/Contents/Resources/Animations/"
  cp "$MEDIA_ADAPTER_SCRIPT_SOURCE" "$TEMP_APP/Contents/Resources/mediaremote-adapter.pl"
  "$MEDIA_ADAPTER_BUILD_SCRIPT" "$TEMP_APP/Contents/Frameworks" "$SIGNING_IDENTITY"

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
    codesign --verify --deep --strict --verbose=2 \
      "$TEMP_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
  fi
  sign_args=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$APP_ENTITLEMENTS")
  codesign "${sign_args[@]}" "$TEMP_APP"
else
  if [[ "$EDITION" == "lite" ]]; then
    APP_ENTITLEMENTS="$TEMP_DIR/app.entitlements"
    prepare_entitlements "$ENTITLEMENTS_TEMPLATE" "$APP_ENTITLEMENTS"
    codesign --force --deep --sign - --entitlements "$APP_ENTITLEMENTS" "$TEMP_APP"
  else
    APP_ENTITLEMENTS="$TEMP_DIR/app.entitlements"
    prepare_ad_hoc_direct_entitlements "$APP_ENTITLEMENTS"
    codesign --force --sign - "$TEMP_APP/Contents/Helpers/NotchHubHookBridge"
    codesign --force --deep --sign - "$TEMP_APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --deep --sign - \
      "$TEMP_APP/Contents/Frameworks/MediaRemoteAdapter.framework"
    codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$TEMP_APP"
  fi
fi
codesign --verify --deep --strict --verbose=2 "$TEMP_APP"

mkdir -p "$OUTPUT"
rm -rf -- "$OUTPUT/Contents"
ditto "$TEMP_APP/Contents" "$OUTPUT/Contents"
xattr -cr "$OUTPUT"
codesign --verify --deep --strict --verbose=2 "$OUTPUT"
echo "✓ Built $OUTPUT"
