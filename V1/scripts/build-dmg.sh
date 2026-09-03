#!/usr/bin/env bash
#
# Builds the universal NotchHub V1 Preview app and packages it as a verified
# drag-to-Applications DMG. A SHA-256 sidecar is emitted beside the image.
#
# By default the app is ad-hoc signed. For a distributable preview, provide a
# Developer ID Application identity and an optional notarytool keychain profile:
#
#   export NOTCHHUB_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export NOTCHHUB_TEAM_ID="TEAMID"
#   export NOTCHHUB_NOTARY_PROFILE="NotchHubNotary"
#   ./scripts/build-dmg.sh release
#
# Usage: ./scripts/build-dmg.sh [release] [--output PATH] [--skip-build]
#
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "$ROOT/.." && pwd -P)"
readonly BUILD_SCRIPT="$SCRIPT_DIR/build-app.sh"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly LICENSE_SOURCE="$REPOSITORY_ROOT/LICENSE"

readonly APP_BUNDLE_NAME="NotchHub V1 Preview.app"
readonly APP_EXECUTABLE="NotchHubV1"
readonly APP_IDENTIFIER="com.notchhub.v1.preview"
readonly HELPER_EXECUTABLE="NotchHubHookBridge"
readonly SPARKLE_BINARY_RELATIVE_PATH="Contents/Frameworks/Sparkle.framework/Sparkle"

readonly SIGNING_IDENTITY="${NOTCHHUB_SIGNING_IDENTITY:-}"
readonly NOTARY_PROFILE="${NOTCHHUB_NOTARY_PROFILE:-}"
readonly TEAM_IDENTIFIER="${NOTCHHUB_TEAM_ID:-}"

OUTPUT_ARGUMENT=""
OUTPUT_WAS_SET=false
RELEASE_WAS_SET=false
SKIP_BUILD=false
WORK_DIR=""
PUBLISH_DIR=""
OUTPUT_DIR=""
OUTPUT_PATH=""
CHECKSUM_PATH=""
APP_PATH=""
MOUNT_POINT=""
IS_MOUNTED=false
NOTARIZED=false
EXPECTED_TEAM_IDENTIFIER=""

usage() {
  printf '%s\n' \
    "Usage: $0 [release] [OPTIONS]" \
    "" \
    "Build the universal $APP_BUNDLE_NAME and create a compressed DMG containing:" \
    "  • $APP_BUNDLE_NAME" \
    "  • A shortcut to /Applications" \
    "  • The repository's Apache-2.0 LICENSE" \
    "" \
    "Options:" \
    "  --output PATH  Destination DMG (default:" \
    "                 dist/NotchHub-V1-Preview-<version>-universal.dmg)." \
    "                 Relative paths are resolved from the V1 directory." \
    "  --skip-build   Package the existing V1 app bundle without rebuilding it." \
    "  -h, --help     Show this help message." \
    "" \
    "The V1 preview DMG is release-only and always requires arm64 + x86_64 binaries."
}

log_info() {
  printf '▸ %s\n' "$*"
}

log_warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

handle_error() {
  local -r exit_code="$?"
  local -r line_number="$1"
  printf 'error: V1 DMG packaging failed at line %s (exit %s).\n' \
    "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

cleanup() {
  if [[ "$IS_MOUNTED" == "true" && -n "$MOUNT_POINT" ]]; then
    if ! hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1; then
      log_warn "Could not detach temporary mount at $MOUNT_POINT."
    fi
  fi

  if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/notchhub-v1-dmg.* && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR" || log_warn "Could not remove temporary directory $WORK_DIR."
  fi

  if [[ -n "$PUBLISH_DIR" && -n "$OUTPUT_DIR" && \
    "$PUBLISH_DIR" == "$OUTPUT_DIR"/.notchhub-v1-publish.* && -d "$PUBLISH_DIR" ]]; then
    rm -rf -- "$PUBLISH_DIR" || log_warn "Could not remove temporary directory $PUBLISH_DIR."
  fi
}

require_command() {
  local -r command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "Required command is unavailable: $command_name"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      release)
        [[ "$RELEASE_WAS_SET" == "false" ]] || fail "Release configuration was supplied more than once."
        RELEASE_WAS_SET=true
        shift
        ;;
      debug)
        fail "V1 preview DMGs are release-only so every packaged binary can be universal."
        ;;
      --output)
        [[ $# -ge 2 && -n "$2" ]] || fail "--output requires a path."
        [[ "$OUTPUT_WAS_SET" == "false" ]] || fail "--output was supplied more than once."
        OUTPUT_ARGUMENT="$2"
        OUTPUT_WAS_SET=true
        shift 2
        ;;
      --skip-build)
        SKIP_BUILD=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        [[ $# -eq 0 ]] || fail "Unexpected positional arguments: $*"
        ;;
      *)
        fail "Unknown argument: $1 (run with --help for usage)."
        ;;
    esac
  done
}

validate_release_environment() {
  local certificate_pem certificate_subject certificate_team_identifier

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    [[ "$SIGNING_IDENTITY" == "Developer ID Application: "* ]] || \
      fail "NOTCHHUB_SIGNING_IDENTITY must select a Developer ID Application certificate."
    [[ "$SIGNING_IDENTITY" != *$'\n'* && "$SIGNING_IDENTITY" != *$'\r'* ]] || \
      fail "NOTCHHUB_SIGNING_IDENTITY contains an invalid control character."
    require_command openssl
    require_command security
    if ! certificate_pem="$(security find-certificate -c "$SIGNING_IDENTITY" -p 2>/dev/null)" || \
      [[ -z "$certificate_pem" ]]; then
      fail "Could not resolve the requested Developer ID signing certificate."
    fi
    if ! certificate_subject="$(printf '%s\n' "$certificate_pem" | \
      openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)"; then
      fail "Could not inspect the Developer ID certificate Team ID."
    fi
    if [[ "$certificate_subject" =~ (^|,)OU=([A-Z0-9]{10})(,|$) ]]; then
      certificate_team_identifier="${BASH_REMATCH[2]}"
    else
      fail "Developer ID certificate is missing a 10-character Apple Team ID."
    fi
    EXPECTED_TEAM_IDENTIFIER="$certificate_team_identifier"

    if [[ -n "$TEAM_IDENTIFIER" ]]; then
      [[ "$TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]] || \
        fail "NOTCHHUB_TEAM_ID must be a 10-character Apple Team ID."
      [[ "$TEAM_IDENTIFIER" == "$EXPECTED_TEAM_IDENTIFIER" ]] || \
        fail "NOTCHHUB_TEAM_ID does not match the Developer ID identity."
    fi
  fi

  if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ -n "$SIGNING_IDENTITY" ]] || \
      fail "NOTCHHUB_NOTARY_PROFILE requires NOTCHHUB_SIGNING_IDENTITY."
    [[ "$NOTARY_PROFILE" != *$'\n'* && "$NOTARY_PROFILE" != *$'\r'* ]] || \
      fail "NOTCHHUB_NOTARY_PROFILE contains an invalid control character."
  fi
}

validate_license_source() {
  [[ -f "$LICENSE_SOURCE" && ! -L "$LICENSE_SOURCE" ]] || \
    fail "Repository license is missing or symlinked: $LICENSE_SOURCE"
  grep -F 'Apache License' "$LICENSE_SOURCE" >/dev/null || \
    fail "Repository LICENSE is not the expected Apache license."
  grep -F 'Version 2.0, January 2004' "$LICENSE_SOURCE" >/dev/null || \
    fail "Repository LICENSE is not Apache License 2.0."
}

read_plist_value() {
  local -r plist_path="$1"
  local -r key_path="$2"
  "$PLIST_BUDDY" -c "Print :$key_path" "$plist_path"
}

read_app_version() {
  local -r bundle_path="$1"
  local version
  version="$(read_plist_value "$bundle_path/Contents/Info.plist" CFBundleShortVersionString)"
  [[ -n "$version" ]] || fail "CFBundleShortVersionString is empty."
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "App version contains characters that are unsafe in a filename: $version"
  printf '%s' "$version"
}

verify_universal_binary() {
  local -r binary_path="$1"
  local architectures

  # A versioned framework exposes its binary through a relative in-bundle
  # symlink. validate_app_structure has already confined that link to the
  # framework, while the main app and helper paths are explicitly non-symlinked.
  [[ -f "$binary_path" ]] || fail "Expected a Mach-O binary: $binary_path"
  architectures="$(lipo -archs "$binary_path")"
  case "$architectures" in
    "arm64 x86_64" | "x86_64 arm64") ;;
    *) fail "Binary is not universal arm64 + x86_64: $binary_path ($architectures)" ;;
  esac
}

verify_all_macho_binaries_are_universal() {
  local -r bundle_path="$1"
  local binary_path file_description manifest
  local macho_count=0

  manifest="$(mktemp "$WORK_DIR/macho-files.XXXXXX")"
  find "$bundle_path" -type f -print0 >"$manifest" || \
    fail "Could not enumerate regular files in app bundle: $bundle_path"
  while IFS= read -r -d '' binary_path; do
    file_description="$(file -b "$binary_path")" || \
      fail "Could not identify app-bundle file: $binary_path"
    if [[ "$file_description" == *Mach-O* ]]; then
      macho_count=$((macho_count + 1))
      verify_universal_binary "$binary_path"
    fi
  done <"$manifest"

  [[ "$macho_count" -gt 0 ]] || fail "App bundle contains no Mach-O binaries: $bundle_path"
}

# Framework bundles legitimately contain versioning symlinks. Every accepted
# link must be relative, resolve inside Sparkle.framework, and point to an
# existing object. All links elsewhere in the app are rejected.
validate_bundle_symlinks() {
  local -r bundle_path="$1"
  local bundle_root framework_root link target resolved symlink_manifest

  bundle_root="$(cd -- "$bundle_path" && pwd -P)"
  framework_root="$bundle_root/Contents/Frameworks/Sparkle.framework"
  symlink_manifest="$(mktemp "$WORK_DIR/symlinks.XXXXXX")"
  find "$bundle_path" -type l -print0 >"$symlink_manifest" || \
    fail "Could not inspect app-bundle symlinks: $bundle_path"
  while IFS= read -r -d '' link; do
    case "$link" in
      "$bundle_path"/Contents/Frameworks/Sparkle.framework/*) ;;
      *) fail "Refusing to package an unexpected symlink: $link" ;;
    esac

    target="$(readlink "$link")"
    [[ -n "$target" && "$target" != /* ]] || \
      fail "Refusing to package an absolute or empty framework symlink: $link -> $target"
    [[ -e "$link" ]] || fail "Refusing to package a dangling framework symlink: $link -> $target"

    resolved="$(realpath "$link")" || fail "Could not resolve framework symlink: $link -> $target"
    case "$resolved" in
      "$framework_root" | "$framework_root"/*) ;;
      *) fail "Framework symlink escapes the bundle: $link -> $target" ;;
    esac
  done <"$symlink_manifest"
}

validate_app_structure() {
  local -r bundle_path="$1"
  local -r plist_path="$bundle_path/Contents/Info.plist"
  local -r main_binary="$bundle_path/Contents/MacOS/$APP_EXECUTABLE"
  local -r helper_binary="$bundle_path/Contents/Helpers/$HELPER_EXECUTABLE"
  local -r sparkle_binary="$bundle_path/$SPARKLE_BINARY_RELATIVE_PATH"
  local path bundle_name bundle_identifier bundle_executable package_type
  local -a checked_paths=(
    "$bundle_path"
    "$bundle_path/Contents"
    "$plist_path"
    "$bundle_path/Contents/MacOS"
    "$main_binary"
    "$bundle_path/Contents/Helpers"
    "$helper_binary"
    "$bundle_path/Contents/Frameworks"
    "$bundle_path/Contents/Frameworks/Sparkle.framework"
  )

  [[ -d "$bundle_path" ]] || fail "App bundle does not exist: $bundle_path"
  for path in "${checked_paths[@]}"; do
    [[ ! -L "$path" ]] || fail "Refusing to package a symlinked required path: $path"
  done
  [[ -f "$plist_path" ]] || fail "App bundle is missing Info.plist: $plist_path"
  [[ -f "$main_binary" ]] || fail "App bundle is missing its executable: $main_binary"
  [[ -f "$helper_binary" ]] || fail "App bundle is missing its hook helper: $helper_binary"
  [[ -f "$sparkle_binary" ]] || fail "App bundle is missing the Sparkle binary: $sparkle_binary"

  bundle_name="$(read_plist_value "$plist_path" CFBundleName)"
  bundle_identifier="$(read_plist_value "$plist_path" CFBundleIdentifier)"
  bundle_executable="$(read_plist_value "$plist_path" CFBundleExecutable)"
  package_type="$(read_plist_value "$plist_path" CFBundlePackageType)"
  [[ "$bundle_name" == "NotchHub V1 Preview" ]] || \
    fail "Unexpected product name in app bundle: $bundle_name"
  [[ "$bundle_identifier" == "$APP_IDENTIFIER" ]] || \
    fail "Unexpected V1 preview bundle identifier: $bundle_identifier"
  [[ "$bundle_executable" == "$APP_EXECUTABLE" ]] || \
    fail "Unexpected V1 preview executable: $bundle_executable"
  [[ "$package_type" == "APPL" ]] || fail "Unexpected bundle package type: $package_type"

  validate_bundle_symlinks "$bundle_path"
}

verify_expected_signer() {
  local -r bundle_path="$1"
  local -r helper_path="$bundle_path/Contents/Helpers/$HELPER_EXECUTABLE"
  local signing_details helper_signing_details app_entitlements helper_entitlements
  local app_signing_identifier helper_signing_identifier

  signing_details="$(codesign -dvvv "$bundle_path" 2>&1)"
  helper_signing_details="$(codesign -dvvv "$helper_path" 2>&1)"
  app_signing_identifier="$(awk -F= '/^Identifier=/ {
    print substr($0, index($0, "=") + 1)
    exit
  }' <<<"$signing_details")"
  helper_signing_identifier="$(awk -F= '/^Identifier=/ {
    print substr($0, index($0, "=") + 1)
    exit
  }' <<<"$helper_signing_details")"
  [[ "$app_signing_identifier" == "$APP_IDENTIFIER" ]] || \
    fail "App code-signing identifier does not match the V1 preview identity."
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    grep -F 'Signature=adhoc' <<<"$signing_details" >/dev/null || \
      fail "Unsigned preview mode requires an ad-hoc app signature."
    grep -F 'Signature=adhoc' <<<"$helper_signing_details" >/dev/null || \
      fail "Unsigned preview mode requires an ad-hoc hook-helper signature."
    grep -F 'TeamIdentifier=not set' <<<"$signing_details" >/dev/null || \
      fail "Ad-hoc preview app unexpectedly carries an Apple Team ID."
    grep -F 'TeamIdentifier=not set' <<<"$helper_signing_details" >/dev/null || \
      fail "Ad-hoc preview hook helper unexpectedly carries an Apple Team ID."
    app_entitlements="$(codesign -d --entitlements :- "$bundle_path" 2>/dev/null)" || \
      fail "Could not inspect ad-hoc app entitlements."
    helper_entitlements="$(codesign -d --entitlements :- "$helper_path" 2>/dev/null)" || \
      fail "Could not inspect ad-hoc hook-helper entitlements."
    if grep -F 'keychain-access-groups' <<<"$app_entitlements" >/dev/null || \
      grep -F 'keychain-access-groups' <<<"$helper_entitlements" >/dev/null; then
      fail "Ad-hoc preview must not carry shared keychain-group entitlements."
    fi
    return 0
  fi

  [[ "$helper_signing_identifier" == "com.notchhub.v1.bridge.helper" ]] || \
    fail "Hook-helper code-signing identifier is incompatible with secure installation."
  grep -F "Authority=$SIGNING_IDENTITY" <<<"$signing_details" >/dev/null || \
    fail "App was not signed by the requested Developer ID identity."
  grep -F "Authority=$SIGNING_IDENTITY" <<<"$helper_signing_details" >/dev/null || \
    fail "Hook helper was not signed by the requested Developer ID identity."
  grep -F "TeamIdentifier=$EXPECTED_TEAM_IDENTIFIER" <<<"$signing_details" >/dev/null || \
    fail "App signature has an unexpected Apple Team ID."
  grep -F "TeamIdentifier=$EXPECTED_TEAM_IDENTIFIER" <<<"$helper_signing_details" >/dev/null || \
    fail "Hook-helper signature has an unexpected Apple Team ID."
  grep -E '^CodeDirectory .*flags=.*\(runtime\)' <<<"$signing_details" >/dev/null || \
    fail "Developer ID app signature does not enable the hardened runtime."
  grep -E '^CodeDirectory .*flags=.*\(runtime\)' <<<"$helper_signing_details" >/dev/null || \
    fail "Developer ID hook-helper signature does not enable the hardened runtime."
}

verify_keychain_entitlements() {
  local -r bundle_path="$1"
  local -r helper_path="$bundle_path/Contents/Helpers/$HELPER_EXECUTABLE"
  local entitlement_dir app_entitlements helper_entitlements expected_group app_group helper_group

  [[ -n "$SIGNING_IDENTITY" ]] || return 0
  expected_group="$EXPECTED_TEAM_IDENTIFIER.com.notchhub.v1.bridge"
  entitlement_dir="$(mktemp -d "$WORK_DIR/entitlements.XXXXXX")"
  app_entitlements="$entitlement_dir/app.plist"
  helper_entitlements="$entitlement_dir/helper.plist"
  if ! codesign -d --entitlements :- "$bundle_path" >"$app_entitlements" 2>/dev/null || \
    ! codesign -d --entitlements :- "$helper_path" >"$helper_entitlements" 2>/dev/null; then
    fail "Could not read Developer ID keychain entitlements."
  fi

  app_group="$(read_plist_value "$app_entitlements" 'keychain-access-groups:0' 2>/dev/null || true)"
  helper_group="$(read_plist_value "$helper_entitlements" 'keychain-access-groups:0' 2>/dev/null || true)"
  [[ "$app_group" == "$expected_group" ]] || \
    fail "App keychain group does not match the Developer ID Team ID."
  [[ "$helper_group" == "$expected_group" ]] || \
    fail "Hook-helper keychain group does not match the Developer ID Team ID."
}

verify_app_bundle() {
  local -r bundle_path="$1"
  local -r main_binary="$bundle_path/Contents/MacOS/$APP_EXECUTABLE"
  local -r helper_binary="$bundle_path/Contents/Helpers/$HELPER_EXECUTABLE"
  local main_linkage main_load_commands helper_linkage helper_symbols

  validate_app_structure "$bundle_path"
  codesign --verify --deep --strict --verbose=2 "$bundle_path"
  codesign --verify --strict --verbose=2 "$helper_binary"
  codesign --verify --deep --strict --verbose=2 \
    "$bundle_path/Contents/Frameworks/Sparkle.framework"
  verify_expected_signer "$bundle_path"
  verify_keychain_entitlements "$bundle_path"

  verify_all_macho_binaries_are_universal "$bundle_path"

  main_linkage="$(otool -L "$main_binary")"
  grep -F '@rpath/Sparkle.framework/' <<<"$main_linkage" >/dev/null || \
    fail "V1 executable does not link the packaged Sparkle framework."
  main_load_commands="$(otool -l "$main_binary")"
  grep -F '@executable_path/../Frameworks' <<<"$main_load_commands" >/dev/null || \
    fail "V1 executable is missing its packaged-framework runtime path."

  helper_linkage="$(otool -L "$helper_binary")"
  if grep -E '/(AppKit|SwiftUI)\.framework/' <<<"$helper_linkage" >/dev/null; then
    fail "Hook helper must not link user-interface frameworks."
  fi
  helper_symbols="$(nm "$helper_binary")"
  if grep -E 'NotchHub(SafeFeatures|Core)' <<<"$helper_symbols" >/dev/null; then
    fail "Hook helper contains application or Store-safe feature code."
  fi
}

build_or_select_app() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    APP_PATH="$ROOT/$APP_BUNDLE_NAME"
    log_info "Using the existing $APP_PATH (--skip-build)."
    return
  fi

  local -r build_output="$WORK_DIR/build-output"
  mkdir -p "$build_output"
  log_info "Building the universal $APP_BUNDLE_NAME (release)…"
  NOTCHHUB_OUTPUT_DIR="$build_output" \
    NOTCHHUB_UNIVERSAL=1 \
    NOTCHHUB_RELEASE=0 \
    NOTCHHUB_OFFICIAL_RELEASE=0 \
    NOTCHHUB_UPDATE_FEED_URL="" \
    NOTCHHUB_UPDATE_PUBLIC_KEY="" \
    "$BUILD_SCRIPT" direct release
  APP_PATH="$build_output/$APP_BUNDLE_NAME"
}

resolve_output_path() {
  local -r app_version="$1"
  local requested_path requested_dir output_name canonical_dir

  if [[ -z "$OUTPUT_ARGUMENT" ]]; then
    requested_path="$ROOT/dist/NotchHub-V1-Preview-$app_version-universal.dmg"
  elif [[ "$OUTPUT_ARGUMENT" == /* ]]; then
    requested_path="$OUTPUT_ARGUMENT"
  else
    requested_path="$ROOT/$OUTPUT_ARGUMENT"
  fi

  [[ "$requested_path" != *$'\n'* && "$requested_path" != *$'\r'* ]] || \
    fail "Output path contains an invalid control character."
  [[ "$requested_path" == *.dmg ]] || fail "Output path must end in .dmg: $requested_path"
  requested_dir="$(dirname -- "$requested_path")"
  output_name="$(basename -- "$requested_path")"
  [[ "$output_name" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*\.dmg$ ]] || \
    fail "Output filename contains unsupported characters: $output_name"

  [[ ! -L "$requested_dir" ]] || fail "Output directory must not be a symlink: $requested_dir"
  mkdir -p "$requested_dir"
  canonical_dir="$(cd -- "$requested_dir" && pwd -P)"
  [[ "$canonical_dir" != "/" ]] || fail "Refusing to publish release artifacts at the filesystem root."
  OUTPUT_DIR="$canonical_dir"
  OUTPUT_PATH="$OUTPUT_DIR/$output_name"
  CHECKSUM_PATH="$OUTPUT_PATH.sha256"

  if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
    fail "Release DMGs are immutable; refusing to replace existing output: $OUTPUT_PATH"
  fi
  if [[ -e "$CHECKSUM_PATH" || -L "$CHECKSUM_PATH" ]]; then
    fail "Release checksums are immutable; refusing to replace existing output: $CHECKSUM_PATH"
  fi
}

create_disk_image() {
  local -r staging_dir="$1"
  local -r volume_name="$2"
  local -r image_path="$3"

  hdiutil create \
    -srcfolder "$staging_dir" \
    -volname "$volume_name" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -nospotlight \
    -quiet \
    "$image_path"
}

verify_mounted_image() {
  local -r image_path="$1"

  MOUNT_POINT="$WORK_DIR/mount"
  mkdir -p "$MOUNT_POINT"
  hdiutil attach "$image_path" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    -quiet
  IS_MOUNTED=true

  [[ -d "$MOUNT_POINT/$APP_BUNDLE_NAME" ]] || \
    fail "DMG does not contain $APP_BUNDLE_NAME."
  [[ -L "$MOUNT_POINT/Applications" ]] || \
    fail "DMG does not contain an Applications shortcut."
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || \
    fail "Applications shortcut has an unexpected target."
  [[ -f "$MOUNT_POINT/LICENSE" && ! -L "$MOUNT_POINT/LICENSE" ]] || \
    fail "DMG does not contain the Apache-2.0 LICENSE."
  cmp -s "$LICENSE_SOURCE" "$MOUNT_POINT/LICENSE" || \
    fail "Packaged LICENSE does not match the repository's Apache-2.0 LICENSE."
  verify_app_bundle "$MOUNT_POINT/$APP_BUNDLE_NAME"

  hdiutil detach "$MOUNT_POINT" -quiet
  IS_MOUNTED=false
}

sign_disk_image() {
  local -r image_path="$1"
  [[ -n "$SIGNING_IDENTITY" ]] || return 0

  log_info "Signing the disk image with Developer ID…"
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$image_path"
  codesign --verify --verbose=2 "$image_path"
}

notarize_disk_image() {
  local -r image_path="$1"
  [[ -n "$NOTARY_PROFILE" ]] || return 0

  require_command xcrun
  log_info "Submitting the disk image to Apple's notary service…"
  xcrun notarytool submit "$image_path" --keychain-profile "$NOTARY_PROFILE" --wait
  log_info "Stapling and validating the notarization ticket…"
  xcrun stapler staple "$image_path"
  xcrun stapler validate "$image_path"
  NOTARIZED=true
}

read_signing_authority() {
  local authority=""
  authority="$(codesign -dvvv "$APP_PATH" 2>&1 | \
    awk -F'=' '/^Authority=/ && !seen { print $2; seen = 1 }')" || true
  printf '%s' "${authority:-ad-hoc (no Developer ID)}"
}

assess_gatekeeper() {
  local -r image_path="$1"
  if spctl --assess --type open --context context:primary-signature "$image_path" >/dev/null 2>&1; then
    printf 'accepted'
  else
    printf 'rejected (expected for an unnotarized preview)'
  fi
}

publish_artifacts() {
  local -r source_image="$1"
  local -r output_name="$(basename -- "$OUTPUT_PATH")"
  local -r checksum_name="$(basename -- "$CHECKSUM_PATH")"
  local candidate_image candidate_checksum checksum

  PUBLISH_DIR="$(mktemp -d "$OUTPUT_DIR/.notchhub-v1-publish.XXXXXX")"
  candidate_image="$PUBLISH_DIR/$output_name"
  candidate_checksum="$PUBLISH_DIR/$checksum_name"
  ditto "$source_image" "$candidate_image"

  sign_disk_image "$candidate_image"
  notarize_disk_image "$candidate_image"
  hdiutil verify "$candidate_image" -quiet
  verify_mounted_image "$candidate_image"

  if [[ "$NOTARIZED" == "true" ]]; then
    spctl --assess --type open --context context:primary-signature "$candidate_image" || \
      fail "Gatekeeper rejected the notarized disk image."
  fi

  checksum="$(shasum -a 256 "$candidate_image" | awk '{print $1}')"
  [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || fail "Could not compute a valid SHA-256 checksum."
  printf '%s  %s\n' "$checksum" "$output_name" >"$candidate_checksum"
  (cd -- "$PUBLISH_DIR" && shasum -a 256 -c "$checksum_name")

  if ! ln "$candidate_image" "$OUTPUT_PATH"; then
    fail "Could not publish immutable DMG; the destination may already exist: $OUTPUT_PATH"
  fi
  if ! ln "$candidate_checksum" "$CHECKSUM_PATH"; then
    if ! rm -f -- "$OUTPUT_PATH"; then
      fail "Could not publish checksum or roll back partially published DMG: $OUTPUT_PATH"
    fi
    fail "Could not publish immutable checksum; no artifact pair was retained."
  fi
  (cd -- "$OUTPUT_DIR" && shasum -a 256 -c "$checksum_name")
}

main() {
  local app_version volume_name staging_dir temporary_dmg

  parse_arguments "$@"
  validate_release_environment

  require_command awk
  require_command codesign
  require_command cmp
  require_command ditto
  require_command file
  require_command find
  require_command grep
  require_command hdiutil
  require_command lipo
  require_command ln
  require_command mktemp
  require_command nm
  require_command otool
  require_command readlink
  require_command realpath
  require_command shasum
  require_command spctl
  require_command xattr
  [[ -x "$PLIST_BUDDY" ]] || fail "Required tool is unavailable: $PLIST_BUDDY"
  [[ -x "$BUILD_SCRIPT" ]] || fail "App build script is not executable: $BUILD_SCRIPT"
  validate_license_source

  WORK_DIR="$(mktemp -d /tmp/notchhub-v1-dmg.XXXXXX)"
  build_or_select_app
  verify_app_bundle "$APP_PATH"
  app_version="$(read_app_version "$APP_PATH")"
  resolve_output_path "$app_version"

  staging_dir="$WORK_DIR/staging"
  temporary_dmg="$WORK_DIR/NotchHub-V1-Preview.dmg"
  volume_name="NotchHub V1 $app_version"
  mkdir -p "$staging_dir"

  log_info "Staging the verified app and Applications shortcut…"
  ditto "$APP_PATH" "$staging_dir/$APP_BUNDLE_NAME"
  xattr -cr "$staging_dir/$APP_BUNDLE_NAME"
  verify_app_bundle "$staging_dir/$APP_BUNDLE_NAME"
  ln -s /Applications "$staging_dir/Applications"
  ditto "$LICENSE_SOURCE" "$staging_dir/LICENSE"

  log_info "Creating and mounting the compressed disk image…"
  create_disk_image "$staging_dir" "$volume_name" "$temporary_dmg"
  hdiutil verify "$temporary_dmg" -quiet
  verify_mounted_image "$temporary_dmg"

  log_info "Publishing the verified immutable DMG and checksum…"
  publish_artifacts "$temporary_dmg"

  printf '✓ Created %s\n' "$OUTPUT_PATH"
  printf '  Checksum:     %s\n' "$CHECKSUM_PATH"
  printf '  Architecture: universal (arm64 + x86_64)\n'
  printf '  Signed by:    %s\n' "$(read_signing_authority)"
  if [[ "$NOTARIZED" == "true" ]]; then
    printf '  Notarized:    yes (ticket stapled)\n'
  else
    printf '  Notarized:    no\n'
  fi
  printf '  Gatekeeper:   %s\n' "$(assess_gatekeeper "$OUTPUT_PATH")"
  if [[ "$NOTARIZED" != "true" ]]; then
    printf '  ⚠︎ This preview is not notarized and macOS may block it on other Macs.\n'
    printf '    Publish it only with that limitation clearly disclosed.\n'
  fi
}

trap cleanup EXIT
trap 'handle_error "$LINENO"' ERR

main "$@"
