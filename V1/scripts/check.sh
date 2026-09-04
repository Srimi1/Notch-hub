#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$ROOT/.." && pwd)"
LOTTIE_PRIVACY_MANIFEST_SOURCE="$ROOT/Resources/ThirdParty/Lottie-PrivacyInfo.xcprivacy"
LOTTIE_PRIVACY_MANIFEST_SHA256="10da67f217824f019288ec328ababc290ab0399c52e9be77a24d494339137da2"
cd "$ROOT"

FAIL=0

run_gate() {
  local title="$1"
  shift
  printf '\n\033[1m▸ %s\033[0m\n' "$title"
  if "$@"; then
    echo "✓ $title"
  else
    echo "✗ $title" >&2
    FAIL=1
  fi
}

format_lint() {
  swift package --disable-sandbox --allow-writing-to-package-directory \
    swiftformat Sources Tests --lint
}

swift_lint() {
  swift package --disable-sandbox --allow-writing-to-package-directory swiftlint
}

strict_concurrency() {
  swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
}

secret_scan() {
  local pattern='(sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|api[_-]?key.{0,8}[A-Za-z0-9_-]{16,})'
  if rg --hidden --glob '!Package.resolved' --glob '!.build/**' --glob '!scripts/check.sh' \
    --regexp "$pattern" Sources Tests Resources; then
    echo "credential-like material found" >&2
    return 1
  fi
}

dependency_audit() {
  swift package --force-resolved-versions \
    --resolver-fingerprint-checking strict \
    --resolver-signing-entity-checking strict \
    show-dependencies --format json >/dev/null
}

release_tooling() {
  [[ -x "$ROOT/scripts/build-dmg.sh" ]] || {
    echo "V1 DMG builder is missing or not executable" >&2
    return 1
  }
  bash -n "$ROOT/scripts/build-app.sh" "$ROOT/scripts/build-dmg.sh" "$ROOT/scripts/check.sh" || return 1
  "$ROOT/scripts/build-dmg.sh" --help >/dev/null
}

validate_lottie_privacy_manifest() {
  local manifest_path="$1"
  local actual_hash tracking api_type api_reason

  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || {
    echo "Lottie privacy manifest is missing or symlinked: $manifest_path" >&2
    return 1
  }
  /usr/bin/plutil -lint "$manifest_path" >/dev/null || return 1
  actual_hash="$(/usr/bin/shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}')" || return 1
  [[ "$actual_hash" == "$LOTTIE_PRIVACY_MANIFEST_SHA256" ]] || {
    echo "Lottie privacy manifest does not match the pinned 4.6.1 manifest" >&2
    return 1
  }
  tracking="$(/usr/libexec/PlistBuddy -c \
    'Print :NSPrivacyTracking' "$manifest_path" 2>/dev/null)" || return 1
  api_type="$(/usr/libexec/PlistBuddy -c \
    'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType' \
    "$manifest_path" 2>/dev/null)" || return 1
  api_reason="$(/usr/libexec/PlistBuddy -c \
    'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0' \
    "$manifest_path" 2>/dev/null)" || return 1
  [[ "$tracking" == "false" && \
    "$api_type" == "NSPrivacyAccessedAPICategoryFileTimestamp" && \
    "$api_reason" == "C617.1" ]] || {
    echo "Lottie privacy manifest is missing its required-reason declaration" >&2
    return 1
  }
}

verify_media_bundle_contents() {
  local bundle="$1"
  local edition="$2"
  local framework="$bundle/Contents/Frameworks/MediaRemoteAdapter.framework"
  local animation="$bundle/Contents/Resources/Animations/astronaut-and-music.json"
  local adapter_script="$bundle/Contents/Resources/mediaremote-adapter.pl"
  local notices="$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
  local privacy_manifest="$bundle/Contents/Resources/PrivacyInfo.xcprivacy"
  local third_party="$bundle/Contents/Resources/ThirdParty"
  local path
  local -a media_notice_paths=(
    "$third_party/Lottie-LICENSE.txt"
    "$third_party/Lottie-NOTICE.txt"
    "$third_party/MediaRemoteAdapter-LICENSE.txt"
    "$third_party/MediaRemoteAdapter-NOTICE.txt"
    "$third_party/Astronaut-and-Music-LICENSE.txt"
    "$third_party/Astronaut-and-Music-NOTICE.txt"
  )

  if [[ "$edition" == "direct" ]]; then
    [[ -d "$framework" && ! -L "$framework" ]] || {
      echo "Direct bundle is missing the MediaRemote adapter framework" >&2
      return 1
    }
    for path in "$animation" "$adapter_script" "$notices" "$privacy_manifest" \
      "${media_notice_paths[@]}"; do
      [[ -f "$path" && ! -L "$path" ]] || {
        echo "Direct bundle is missing a regular Media resource: $path" >&2
        return 1
      }
    done
    codesign --verify --deep --strict --verbose=2 "$framework" || return 1
    cmp -s "$REPOSITORY_ROOT/Resources/Animations/astronaut-and-music.json" \
      "$animation" || return 1
    cmp -s "$REPOSITORY_ROOT/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" \
      "$adapter_script" || return 1
    cmp -s "$ROOT/THIRD_PARTY_NOTICES.md" "$notices" || return 1
    cmp -s "$ROOT/Resources/ThirdParty/Lottie-LICENSE.txt" \
      "$third_party/Lottie-LICENSE.txt" || return 1
    validate_lottie_privacy_manifest "$LOTTIE_PRIVACY_MANIFEST_SOURCE" || return 1
    cmp -s "$LOTTIE_PRIVACY_MANIFEST_SOURCE" "$privacy_manifest" || return 1
    validate_lottie_privacy_manifest "$privacy_manifest" || return 1
    cmp -s "$ROOT/Resources/ThirdParty/Lottie-NOTICE.txt" \
      "$third_party/Lottie-NOTICE.txt" || return 1
    cmp -s "$REPOSITORY_ROOT/Vendor/mediaremote-adapter/LICENSE" \
      "$third_party/MediaRemoteAdapter-LICENSE.txt" || return 1
    cmp -s "$ROOT/Resources/ThirdParty/MediaRemoteAdapter-NOTICE.txt" \
      "$third_party/MediaRemoteAdapter-NOTICE.txt" || return 1
    cmp -s "$ROOT/Resources/ThirdParty/Astronaut-and-Music-LICENSE.txt" \
      "$third_party/Astronaut-and-Music-LICENSE.txt" || return 1
    cmp -s "$ROOT/Resources/ThirdParty/Astronaut-and-Music-NOTICE.txt" \
      "$third_party/Astronaut-and-Music-NOTICE.txt" || return 1
    return 0
  fi

  for path in "$framework" "$animation" "$adapter_script" "$notices" "$privacy_manifest" \
    "$third_party"; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "Store Lite must not bundle Direct Media material: $path" >&2
      return 1
    fi
  done
}

verify_direct_entitlements() {
  local bundle="$1"
  local entitlement_file team_identifier automation_group keychain_group key_count
  entitlement_file="$(mktemp /tmp/notchhub-direct-entitlements.XXXXXX)"
  if ! codesign -d --entitlements :- "$bundle" >"$entitlement_file" 2>/dev/null; then
    rm -f -- "$entitlement_file"
    return 1
  fi
  team_identifier="$(codesign -dvvv "$bundle" 2>&1 | awk -F= \
    '/^TeamIdentifier=/ { print $2; exit }')"
  automation_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.automation.apple-events' "$entitlement_file" 2>/dev/null || true)"
  keychain_group="$(/usr/libexec/PlistBuddy -c \
    'Print :keychain-access-groups:0' "$entitlement_file" 2>/dev/null || true)"
  key_count="$(grep -c '<key>' "$entitlement_file" || true)"
  rm -f -- "$entitlement_file"

  if [[ "$automation_group" != "true" ]]; then
    echo "Direct bundle must retain Apple Events automation permission" >&2
    return 1
  fi
  if [[ "$team_identifier" == "not set" ]]; then
    if [[ -n "$keychain_group" || "$key_count" != "1" ]]; then
      echo "Ad-hoc Direct bundle must contain only the automation entitlement" >&2
      return 1
    fi
  elif [[ -z "$keychain_group" ]]; then
    echo "Developer ID Direct bundle must retain its bridge Keychain group" >&2
    return 1
  fi
}

verify_bundles() {
  local found=0
  local found_direct=0
  local found_lite=0
  local failed=0
  local bundle
  for bundle in "$ROOT/NotchHub V1 Preview.app" "$ROOT/NotchHub.app" "$ROOT/NotchHub Lite.app"; do
    if [[ -d "$bundle" ]]; then
      found=1
      if ! codesign --verify --deep --strict --verbose=2 "$bundle"; then
        failed=1
        continue
      fi
      if ! verify_bundle_linkage "$bundle"; then
        failed=1
      fi
      if [[ "$bundle" == "$ROOT/NotchHub Lite.app" ]]; then
        found_lite=1
        if ! verify_lite_entitlements "$bundle"; then
          failed=1
        fi
      else
        found_direct=1
        if ! verify_direct_entitlements "$bundle"; then
          failed=1
        fi
      fi
    fi
  done
  if [[ "${VERIFY_RELEASE:-0}" == "1" && "$found" == "0" ]]; then
    echo "VERIFY_RELEASE=1 but no V1 app bundle exists" >&2
    failed=1
  fi
  if [[ "$found" == "1" && ( "$found_direct" == "0" || "$found_lite" == "0" ) ]]; then
    echo "bundle verification requires both Direct and Lite artifacts" >&2
    failed=1
  fi
  if [[ "${VERIFY_RELEASE:-0}" == "1" && -d "$ROOT/NotchHub V1 Preview.app" ]]; then
    verify_bridge_keychain_entitlements "$ROOT/NotchHub V1 Preview.app" || failed=1
  fi
  if [[ "${VERIFY_RELEASE:-0}" == "1" && -d "$ROOT/NotchHub.app" ]]; then
    verify_bridge_keychain_entitlements "$ROOT/NotchHub.app" || failed=1
  fi
  return "$failed"
}

verify_bundle_linkage() {
  local bundle="$1"
  local executable linkage
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")" || return 1
  local binary="$bundle/Contents/MacOS/$executable"
  [[ -f "$binary" ]] || return 1
  linkage="$(otool -L "$binary")" || return 1
  if grep -E 'MediaRemote(Adapter)?\.framework' <<<"$linkage" >/dev/null; then
    echo "app executables must invoke, never link, the MediaRemote adapter" >&2
    return 1
  fi
  if [[ "$executable" == "NotchHubV1" ]]; then
    local helper="$bundle/Contents/Helpers/NotchHubHookBridge"
    local helper_linkage helper_symbols
    [[ -d "$bundle/Contents/Frameworks/Sparkle.framework" ]] || return 1
    [[ -f "$helper" ]] || return 1
    grep -F '@rpath/Sparkle.framework/' <<<"$linkage" >/dev/null || return 1
    otool -l "$binary" | grep -F '@executable_path/../Frameworks' >/dev/null || return 1
    helper_linkage="$(otool -L "$helper")" || return 1
    if grep -E '/(AppKit|SwiftUI)\.framework/' <<<"$helper_linkage" >/dev/null; then
      echo "bridge helper must not link user-interface frameworks" >&2
      return 1
    fi
    helper_symbols="$(nm "$helper")" || return 1
    if grep -E 'NotchHub(SafeFeatures|Core)' <<<"$helper_symbols" >/dev/null; then
      echo "bridge helper must not contain application or Store-safe feature code" >&2
      return 1
    fi
    verify_media_bundle_contents "$bundle" direct || return 1
  else
    if grep -F 'Sparkle.framework' <<<"$linkage" >/dev/null; then
      echo "Store Lite must not link Sparkle" >&2
      return 1
    fi
    verify_media_bundle_contents "$bundle" lite || return 1
  fi
}

verify_lite_entitlements() {
  local bundle="$1"
  local entitlement_file
  entitlement_file="$(mktemp /tmp/notchhub-lite-entitlements.XXXXXX)"
  if ! codesign -d --entitlements :- "$bundle" >"$entitlement_file" 2>/dev/null; then
    rm -f -- "$entitlement_file"
    return 1
  fi
  local sandboxed
  sandboxed="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlement_file" 2>/dev/null || true)"
  rm -f -- "$entitlement_file"
  if [[ "$sandboxed" != "true" ]]; then
    echo "Store Lite bundle must enable the App Sandbox" >&2
    return 1
  fi
}

fresh_bundle_packaging() {
  local output_dir direct_bundle lite_bundle failed
  output_dir="$(mktemp -d /tmp/notchhub-package-gate.XXXXXX)" || return 1
  direct_bundle="$output_dir/NotchHub V1 Preview.app"
  lite_bundle="$output_dir/NotchHub Lite.app"
  failed=0

  if ! NOTCHHUB_OUTPUT_DIR="$output_dir" NOTCHHUB_UNIVERSAL=0 \
    "$ROOT/scripts/build-app.sh" direct debug; then
    failed=1
  fi
  if ! NOTCHHUB_OUTPUT_DIR="$output_dir" NOTCHHUB_UNIVERSAL=0 \
    "$ROOT/scripts/build-app.sh" lite debug; then
    failed=1
  fi
  for bundle in "$direct_bundle" "$lite_bundle"; do
    if [[ ! -d "$bundle" ]] || ! codesign --verify --deep --strict --verbose=2 "$bundle"; then
      failed=1
      continue
    fi
    verify_bundle_linkage "$bundle" || failed=1
  done
  if [[ -d "$lite_bundle" ]]; then
    verify_lite_entitlements "$lite_bundle" || failed=1
  fi
  if [[ -d "$direct_bundle" ]]; then
    verify_direct_entitlements "$direct_bundle" || failed=1
  fi
  rm -rf -- "$output_dir"
  return "$failed"
}

verify_bridge_keychain_entitlements() {
  local bundle="$1"
  local helper="$bundle/Contents/Helpers/NotchHubHookBridge"
  local entitlement_dir app_entitlements helper_entitlements app_group helper_group
  local app_team helper_team app_identifier helper_identifier expected_app_identifier
  local app_automation helper_automation
  entitlement_dir="$(mktemp -d /tmp/notchhub-entitlements.XXXXXX)"
  app_entitlements="$entitlement_dir/app.plist"
  helper_entitlements="$entitlement_dir/helper.plist"
  if ! codesign -d --entitlements :- "$bundle" >"$app_entitlements" 2>/dev/null ||
    ! codesign -d --entitlements :- "$helper" >"$helper_entitlements" 2>/dev/null; then
    rm -rf -- "$entitlement_dir"
    return 1
  fi
  app_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$app_entitlements" 2>/dev/null || true)"
  helper_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$helper_entitlements" 2>/dev/null || true)"
  app_automation="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.automation.apple-events' "$app_entitlements" 2>/dev/null || true)"
  helper_automation="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.automation.apple-events' "$helper_entitlements" 2>/dev/null || true)"
  app_team="$(codesign -dvvv "$bundle" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
  helper_team="$(codesign -dvvv "$helper" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
  app_identifier="$(codesign -dvvv "$bundle" 2>&1 | awk -F= '/^Identifier=/ { print $2 }')"
  helper_identifier="$(codesign -dvvv "$helper" 2>&1 | awk -F= '/^Identifier=/ { print $2 }')"
  expected_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$bundle/Contents/Info.plist")"
  rm -rf -- "$entitlement_dir"
  [[ -n "$app_team" && "$app_team" == "$helper_team" &&
    "$app_identifier" == "$expected_app_identifier" &&
    "$helper_identifier" == "com.notchhub.v1.bridge.helper" &&
    "$app_group" == "$app_team.com.notchhub.v1.bridge" &&
    "$helper_group" == "$app_group" &&
    "$app_automation" == "true" && -z "$helper_automation" ]]
}

run_gate "Debug build" swift build
run_gate "Test compilation" swift build --build-tests
run_gate "Swift tests" swift test
run_gate "Offline failure simulation" swift test --filter 'RuntimeDirectAgentRuntimeTests.offlineRetention'
run_gate "SwiftFormat" format_lint
run_gate "SwiftLint" swift_lint
run_gate "Strict concurrency" strict_concurrency
run_gate "Credential scan" secret_scan
run_gate "Dependency resolution" dependency_audit
run_gate "Release tooling" release_tooling
run_gate "Fresh app packaging" fresh_bundle_packaging
run_gate "Available bundle signatures" verify_bundles

if [[ "${NOTCHHUB_TSAN:-0}" == "1" ]]; then
  run_gate "Thread sanitizer" swift test --sanitize=thread \
    --filter 'Bridge|Provider|Runtime|Integration'
  run_gate "Media process thread sanitizer" swift test --sanitize=thread \
    --filter 'AdapterProcessLauncherTests'
fi

printf '\n'
if [[ "$FAIL" == "0" ]]; then
  echo "✅ V1 quality gate passed."
else
  echo "❌ V1 quality gate failed." >&2
fi
exit "$FAIL"
