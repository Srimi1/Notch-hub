#!/usr/bin/env bash
#
# Builds NotchHub.app and packages it in a compressed drag-to-Applications DMG.
#
# By default the app carries only the ad-hoc signature produced by build-app.sh.
# That is fine for a local build but **Gatekeeper will refuse it on any other
# Mac**. For a distributable image, provide a Developer ID identity and a
# notarytool keychain profile:
#
#   xcrun notarytool store-credentials NotchHubNotary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   export NOTCHHUB_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export NOTCHHUB_NOTARY_PROFILE="NotchHubNotary"
#   ./scripts/build-dmg.sh release
#
# With both set, the DMG is submitted to Apple, stapled, and Gatekeeper-verified
# before it is published.
#
# Usage: ./scripts/build-dmg.sh [debug|release] [--output PATH] [--skip-build]
#
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly APP_NAME="NotchHub.app"
readonly APP_PATH="$ROOT/$APP_NAME"
readonly BUILD_SCRIPT="$SCRIPT_DIR/build-app.sh"
readonly ICON_PATH="$ROOT/Resources/AppIcon.icns"
readonly PLIST_BUDDY="/usr/libexec/PlistBuddy"
readonly LICENSES_DIR_NAME="Licenses"
# Lottie is a SwiftPM dependency, so its licence text lives in the checkout
# that `swift build` creates rather than under Vendor/.
readonly LOTTIE_LICENSE_PATH="$ROOT/.build/checkouts/lottie-ios/LICENSE"

readonly SIGNING_IDENTITY="${NOTCHHUB_SIGNING_IDENTITY:-}"
readonly NOTARY_PROFILE="${NOTCHHUB_NOTARY_PROFILE:-}"

CONFIG="release"
CONFIG_WAS_SET=false
OUTPUT_ARGUMENT=""
OUTPUT_WAS_SET=false
SKIP_BUILD=false
WORK_DIR=""
PUBLISH_DIR=""
MOUNT_POINT=""
IS_MOUNTED=false
NOTARIZED=false
HAS_CUSTOM_VOLUME_ICON=false
SET_FILE_PATH=""
GET_FILE_INFO_PATH=""

usage() {
  printf '%s\n' \
    "Usage: $0 [debug|release] [OPTIONS]" \
    "" \
    "Build NotchHub.app and create a compressed DMG containing:" \
    "  • NotchHub.app" \
    "  • A shortcut to /Applications" \
    "  • A Licenses folder with every third-party licence the app redistributes" \
    "" \
    "Options:" \
    "  --output PATH  Destination DMG (default: dist/NotchHub-<version>-<arch>.dmg)." \
    "                 Relative paths are resolved from the project root." \
    "  --skip-build   Package the existing NotchHub.app without rebuilding it." \
    "  -h, --help     Show this help message."
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
  printf 'error: DMG packaging failed at line %s (exit %s).\n' \
    "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

cleanup() {
  if [[ "$IS_MOUNTED" == "true" && -n "$MOUNT_POINT" ]]; then
    if ! hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1; then
      log_warn "Could not detach temporary mount at $MOUNT_POINT."
    fi
  fi

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR" || log_warn "Could not remove temporary directory $WORK_DIR."
  fi

  if [[ -n "$PUBLISH_DIR" && -d "$PUBLISH_DIR" ]]; then
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
      debug | release)
        [[ "$CONFIG_WAS_SET" == "false" ]] || fail "Build configuration was supplied more than once."
        CONFIG="$1"
        CONFIG_WAS_SET=true
        shift
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

# With --skip-build the bundle on disk is an *input*, not something this script
# just produced. A symlinked bundle (or a symlinked path component inside it)
# would let `ditto` follow a link out of the project and stage arbitrary content
# into a signed, published disk image, so every part of it must be a real file.
validate_app_bundle() {
  local -r checked_paths=(
    "$APP_PATH"
    "$APP_PATH/Contents"
    "$APP_PATH/Contents/Info.plist"
    "$APP_PATH/Contents/MacOS"
    "$APP_PATH/Contents/MacOS/NotchHub"
    "$APP_PATH/Contents/Resources"
  )

  [[ -d "$APP_PATH" ]] || fail "App bundle does not exist: $APP_PATH"

  local path
  for path in "${checked_paths[@]}"; do
    if [[ -L "$path" ]]; then
      fail "Refusing to package a symlinked path inside the app bundle: $path"
    fi
  done

  [[ -d "$APP_PATH/Contents" ]] || fail "App bundle is missing Contents: $APP_PATH/Contents"
  [[ -f "$APP_PATH/Contents/MacOS/NotchHub" ]] || \
    fail "App bundle is missing a regular executable: $APP_PATH/Contents/MacOS/NotchHub"

  # The bundle used to be flat, and any link at all was treated as tampering.
  # It is not flat any more: MediaRemoteAdapter.framework is a versioned
  # framework, and a versioned framework bundle is *made* of symlinks
  # (Versions/Current, and the three shortcuts beside it). Banning them outright
  # aborted every DMG build.
  #
  # The property that actually matters is unchanged, so it is checked directly
  # instead: a link may only live inside a bundled framework, must be relative,
  # and must resolve to something still inside the app. Anything else could let
  # `ditto` follow a link out of the project and stage arbitrary content into a
  # signed, published disk image.
  local bundle_root link target link_dir resolved
  bundle_root="$(cd "$APP_PATH" && pwd -P)"
  while IFS= read -r -d '' link; do
    case "$link" in
      "$APP_PATH"/Contents/Frameworks/*.framework/*) ;;
      *) fail "Refusing to package an app bundle containing a symlink: $link" ;;
    esac

    target="$(readlink "$link")"
    [[ "$target" != /* ]] || \
      fail "Refusing to package an absolute symlink inside the app bundle: $link -> $target"

    link_dir="$(dirname "$link")"
    resolved="$( (cd "$link_dir" && cd "$(dirname "$target")" && printf '%s/%s' "$(pwd -P)" "$(basename "$target")") 2>/dev/null || true )"
    case "$resolved" in
      "$bundle_root"/*) ;;
      *) fail "Refusing to package a symlink that does not resolve inside the app bundle: $link -> $target" ;;
    esac
  done < <(find "$APP_PATH" -type l -print0)
}

read_app_version() {
  local version
  local -r app_plist="$APP_PATH/Contents/Info.plist"

  [[ -f "$app_plist" ]] || fail "App bundle is missing Info.plist: $app_plist"
  [[ -x "$PLIST_BUDDY" ]] || fail "Required tool is unavailable: $PLIST_BUDDY"

  version="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$app_plist")"
  [[ -n "$version" ]] || fail "CFBundleShortVersionString is empty."
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "App version contains characters that are unsafe in a filename: $version"

  printf '%s' "$version"
}

read_app_architecture() {
  local architectures
  local -r executable_path="$APP_PATH/Contents/MacOS/NotchHub"

  [[ -f "$executable_path" ]] || fail "App bundle is missing its executable: $executable_path"
  architectures="$(lipo -archs "$executable_path")"

  case "$architectures" in
    arm64 | x86_64)
      printf '%s' "$architectures"
      ;;
    "arm64 x86_64" | "x86_64 arm64")
      printf 'universal'
      ;;
    *)
      fail "Unsupported executable architectures: $architectures"
      ;;
  esac
}

prepare_volume_icon() {
  local -r staging_dir="$1"

  [[ -f "$ICON_PATH" ]] || return 0

  if ! command -v xcrun >/dev/null 2>&1 || \
    ! SET_FILE_PATH="$(xcrun --find SetFile 2>/dev/null)" || \
    ! GET_FILE_INFO_PATH="$(xcrun --find GetFileInfo 2>/dev/null)"; then
    log_warn "SetFile is unavailable; the DMG will use the standard volume icon."
    return 0
  fi

  cp "$ICON_PATH" "$staging_dir/.VolumeIcon.icns"
  "$SET_FILE_PATH" -a V "$staging_dir/.VolumeIcon.icns"
  HAS_CUSTOM_VOLUME_ICON=true
}

apply_volume_icon() {
  local -r mount_point="$1"

  [[ "$HAS_CUSTOM_VOLUME_ICON" == "true" ]] || return 0
  "$SET_FILE_PATH" -a C "$mount_point"
}

# Every licence the image redistributes, beside the app where a person can read
# it. BSD-3-Clause, Apache-2.0, MIT and the LottieFiles licence all condition
# redistribution on their notice travelling with the binary, and
# ACKNOWLEDGMENTS.md says the texts ship with the material they cover — which
# was only true of the git tree until this existed.
#
# The list is transitive on purpose. Linking Lottie statically also links the
# libraries it vendors inside its own sources, and upstream Lottie's LICENSE is
# the bare Apache text that does not mention them, so a first pass covering only
# the direct dependencies still under-credited two MIT libraries. See
# Vendor/lottie-embedded/README.md.
stage_licenses() {
  local -r staging_dir="$1"
  local -r licenses_dir="$staging_dir/$LICENSES_DIR_NAME"

  [[ -f "$LOTTIE_LICENSE_PATH" ]] || \
    fail "Lottie licence not found at $LOTTIE_LICENSE_PATH; run swift build first so the checkout exists."

  mkdir -p "$licenses_dir"
  cp "$ROOT/LICENSE" "$licenses_dir/NotchHub-LICENSE.txt"
  cp "$ROOT/ACKNOWLEDGMENTS.md" "$licenses_dir/ACKNOWLEDGMENTS.md"
  cp "$ROOT/Vendor/mediaremote-adapter/LICENSE" "$licenses_dir/mediaremote-adapter-LICENSE.txt"
  cp "$LOTTIE_LICENSE_PATH" "$licenses_dir/Lottie-LICENSE.txt"
  cp "$ROOT/Vendor/purge-app/LICENSE" "$licenses_dir/Purge-LICENSE.txt"
  # Vendored inside Lottie's own sources, so a static link ships them too.
  cp "$ROOT/Vendor/lottie-embedded/ZIPFoundation-LICENSE.txt" "$licenses_dir/ZIPFoundation-LICENSE.txt"
  cp "$ROOT/Vendor/lottie-embedded/LRUCache-LICENSE.txt" "$licenses_dir/LRUCache-LICENSE.txt"
  # The astronaut animation: its licence conditions distribution on these terms
  # accompanying the file.
  cp "$ROOT/Vendor/lottiefiles-astronaut/LICENSE.md" "$licenses_dir/Astronaut-Animation-LICENSE.md"
  # The SwiftPM checkout is read-only and cp keeps the mode; xattr needs to
  # write, and a read-only text file in the image helps nobody anyway.
  chmod 755 "$licenses_dir"
  chmod 644 "$licenses_dir"/*
  xattr -cr "$licenses_dir"
  rewrite_license_links "$licenses_dir"
}

# The two Markdown files were written for the repository, where they sit at the
# root and point into Vendor/. In the image they are siblings in one flat
# folder, so every one of those relative links dangles — and `../../` climbs out
# of the mounted volume entirely. Repoint them at the names they actually have
# here. Web links are left alone; they work from anywhere.
rewrite_license_links() {
  local -r licenses_dir="$1"

  /usr/bin/sed -i '' \
    -e 's|(Vendor/mediaremote-adapter/LICENSE)|(mediaremote-adapter-LICENSE.txt)|g' \
    -e 's|(Vendor/purge-app/LICENSE)|(Purge-LICENSE.txt)|g' \
    -e 's|(Vendor/lottiefiles-astronaut/LICENSE.md)|(Astronaut-Animation-LICENSE.md)|g' \
    -e 's|(Vendor/lottie-embedded/README.md)|(ZIPFoundation-LICENSE.txt)|g' \
    -e 's|(Vendor/mediaremote-adapter/README.md)|(https://github.com/ungive/mediaremote-adapter)|g' \
    -e 's|(Vendor/purge-app/README.md)|(https://github.com/jithin-sabu/purge-app)|g' \
    -e 's|(Resources/Animations/astronaut-and-music.json)|(../NotchHub.app/Contents/Resources/Animations/astronaut-and-music.json)|g' \
    -e 's|(scripts/generate-cache-catalog.py)|(https://github.com/Srimi1/Notch-hub/blob/main/scripts/generate-cache-catalog.py)|g' \
    "$licenses_dir/ACKNOWLEDGMENTS.md"

  /usr/bin/sed -i '' \
    -e 's|(../../ACKNOWLEDGMENTS.md)|(ACKNOWLEDGMENTS.md)|g' \
    "$licenses_dir/Astronaut-Animation-LICENSE.md"

  # Nothing may still point into the repository layout.
  if grep -qE '\]\((Vendor/|Resources/|scripts/|\.\./\.\.)' "$licenses_dir"/*.md; then
    fail "A staged licence file still carries a repository-relative link."
  fi
}

# The files stage_licenses must have produced, checked again on the mounted
# image so a future edit to one cannot silently drop the other.
readonly -a EXPECTED_LICENSE_FILES=(
  "NotchHub-LICENSE.txt"
  "ACKNOWLEDGMENTS.md"
  "mediaremote-adapter-LICENSE.txt"
  "Lottie-LICENSE.txt"
  "ZIPFoundation-LICENSE.txt"
  "LRUCache-LICENSE.txt"
  "Astronaut-Animation-LICENSE.md"
  "Purge-LICENSE.txt"
)

create_compressed_image() {
  local -r staging_dir="$1"
  local -r volume_name="$2"
  local -r writable_dmg="$3"
  local -r compressed_dmg="$4"

  hdiutil create \
    -srcfolder "$staging_dir" \
    -volname "$volume_name" \
    -fs HFS+ \
    -format UDRW \
    -nospotlight \
    -quiet \
    "$writable_dmg"

  MOUNT_POINT="$WORK_DIR/writable-mount"
  mkdir -p "$MOUNT_POINT"
  hdiutil attach "$writable_dmg" \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    -quiet
  IS_MOUNTED=true
  apply_volume_icon "$MOUNT_POINT"
  hdiutil detach "$MOUNT_POINT" -quiet
  IS_MOUNTED=false

  hdiutil convert "$writable_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$compressed_dmg" \
    -quiet
}

verify_mounted_image() {
  local -r image_path="$1"
  local volume_attributes=""

  MOUNT_POINT="$WORK_DIR/mount"
  mkdir -p "$MOUNT_POINT"
  hdiutil attach "$image_path" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    -quiet
  IS_MOUNTED=true

  [[ -d "$MOUNT_POINT/$APP_NAME" ]] || fail "DMG does not contain $APP_NAME."
  [[ -L "$MOUNT_POINT/Applications" ]] || fail "DMG does not contain the Applications shortcut."
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || \
    fail "Applications shortcut has an unexpected target."
  local license_file
  for license_file in "${EXPECTED_LICENSE_FILES[@]}"; do
    [[ -s "$MOUNT_POINT/$LICENSES_DIR_NAME/$license_file" ]] || \
      fail "DMG is missing $LICENSES_DIR_NAME/$license_file."
  done
  codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME"
  if [[ "$HAS_CUSTOM_VOLUME_ICON" == "true" ]]; then
    volume_attributes="$("$GET_FILE_INFO_PATH" -a "$MOUNT_POINT")"
    [[ "$volume_attributes" == *C* ]] || fail "DMG custom volume icon was not preserved."
  fi

  hdiutil detach "$MOUNT_POINT" -quiet
  IS_MOUNTED=false
}

# Reports the app's real signing authority rather than assuming one. Reporting
# must never abort the run under `set -e`, so a failing codesign is absorbed:
# "unknown" is a safe answer, an aborted publish after the DMG already exists is
# not.
read_signing_authority() {
  local authority=""
  # No `exit` in the awk program: quitting early closes the pipe, codesign dies
  # of SIGPIPE, and the ERR trap prints "DMG packaging failed (exit 141)" over a
  # build that in fact succeeded.
  authority="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'=' '/^Authority=/ && !seen { print $2; seen = 1 }')" || true
  printf '%s' "${authority:-ad-hoc (no Developer ID)}"
}

# Submits the finished image to Apple and staples the ticket, so first launch on
# another Mac does not require a network round-trip — or a Gatekeeper override.
notarize_image() {
  local -r image_path="$1"

  [[ -n "$NOTARY_PROFILE" ]] || return 0
  [[ -n "$SIGNING_IDENTITY" ]] || \
    fail "NOTCHHUB_NOTARY_PROFILE is set but NOTCHHUB_SIGNING_IDENTITY is not; Apple cannot notarize an ad-hoc signature."

  require_command xcrun
  log_info "Submitting to the Apple notary service (this can take several minutes)…"
  xcrun notarytool submit "$image_path" --keychain-profile "$NOTARY_PROFILE" --wait
  log_info "Stapling the notarization ticket…"
  xcrun stapler staple "$image_path"
  xcrun stapler validate "$image_path"
  NOTARIZED=true
}

# The honest answer to "will this open on someone else's Mac?".
assess_gatekeeper() {
  local -r image_path="$1"
  if spctl --assess --type open --context context:primary-signature "$image_path" >/dev/null 2>&1; then
    printf 'accepted'
  else
    printf 'rejected (expected for an ad-hoc build)'
  fi
}

main() {
  local app_version
  local app_architecture
  local output_path
  local output_dir
  local output_name
  local staging_dir
  local writable_dmg
  local temporary_dmg
  local published_dmg
  local volume_name
  local checksum_line
  local checksum

  parse_arguments "$@"

  require_command codesign
  require_command ditto
  require_command find
  require_command hdiutil
  require_command lipo
  require_command readlink
  require_command shasum
  require_command spctl
  require_command xattr

  [[ -x "$BUILD_SCRIPT" ]] || fail "App build script is not executable: $BUILD_SCRIPT"

  if [[ "$SKIP_BUILD" == "false" ]]; then
    log_info "Building $APP_NAME ($CONFIG)…"
    "$BUILD_SCRIPT" "$CONFIG"
  else
    log_info "Using the existing $APP_NAME (--skip-build)."
  fi

  validate_app_bundle
  app_version="$(read_app_version)"
  app_architecture="$(read_app_architecture)"
  volume_name="NotchHub $app_version"

  if [[ -z "$OUTPUT_ARGUMENT" ]]; then
    output_path="$ROOT/dist/NotchHub-$app_version-$app_architecture.dmg"
  elif [[ "$OUTPUT_ARGUMENT" == /* ]]; then
    output_path="$OUTPUT_ARGUMENT"
  else
    output_path="$ROOT/$OUTPUT_ARGUMENT"
  fi

  [[ "$output_path" == *.dmg ]] || fail "Output path must end in .dmg: $output_path"
  [[ ! -d "$output_path" ]] || fail "Output path is a directory: $output_path"
  output_dir="$(dirname -- "$output_path")"
  output_name="$(basename -- "$output_path")"
  mkdir -p "$output_dir"

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notchhub-dmg.XXXXXX")"
  PUBLISH_DIR="$(mktemp -d "$output_dir/.notchhub-publish.XXXXXX")"
  staging_dir="$WORK_DIR/staging"
  writable_dmg="$WORK_DIR/NotchHub-writable.dmg"
  temporary_dmg="$WORK_DIR/$output_name"
  published_dmg="$PUBLISH_DIR/$output_name"
  mkdir -p "$staging_dir"

  log_info "Staging $APP_NAME and the Applications shortcut…"
  ditto "$APP_PATH" "$staging_dir/$APP_NAME"
  xattr -cr "$staging_dir/$APP_NAME"
  codesign --verify --deep --strict "$staging_dir/$APP_NAME"
  ln -s /Applications "$staging_dir/Applications"
  log_info "Staging the licence texts…"
  stage_licenses "$staging_dir"
  prepare_volume_icon "$staging_dir"

  log_info "Creating compressed disk image…"
  create_compressed_image "$staging_dir" "$volume_name" "$writable_dmg" "$temporary_dmg"

  log_info "Verifying disk image and packaged app signature…"
  hdiutil verify "$temporary_dmg" -quiet
  verify_mounted_image "$temporary_dmg"

  # Copy to the destination filesystem first, then rename in place so an
  # interrupted copy cannot destroy a previously published image.
  ditto "$temporary_dmg" "$published_dmg"
  mv -f "$published_dmg" "$output_path"

  # Notarization rewrites the image, so the checksum is taken afterwards.
  notarize_image "$output_path"

  checksum_line="$(shasum -a 256 "$output_path")"
  checksum="${checksum_line%% *}"

  printf '✓ Created %s\n' "$output_path"
  printf '  SHA-256:      %s\n' "$checksum"
  printf '  Signed by:    %s\n' "$(read_signing_authority)"
  if [[ "$NOTARIZED" == "true" ]]; then
    printf '  Notarized:    yes (ticket stapled)\n'
  else
    printf '  Notarized:    no\n'
  fi
  printf '  Gatekeeper:   %s\n' "$(assess_gatekeeper "$output_path")"
  if [[ "$NOTARIZED" != "true" ]]; then
    printf '  ⚠︎ This image is not notarized. macOS will block it on other Macs.\n'
    printf '    Set NOTCHHUB_SIGNING_IDENTITY and NOTCHHUB_NOTARY_PROFILE for a\n'
    printf '    distributable build, or publish it as a source/local build only.\n'
  fi
}

trap cleanup EXIT
trap 'handle_error "$LINENO"' ERR

main "$@"
