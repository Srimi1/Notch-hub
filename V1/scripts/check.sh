#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

verify_bundles() {
  local found=0
  local bundle
  for bundle in "$ROOT/NotchHub V1 Preview.app" "$ROOT/NotchHub.app" "$ROOT/NotchHub Lite.app"; do
    if [[ -d "$bundle" ]]; then
      found=1
      codesign --verify --deep --strict --verbose=2 "$bundle"
    fi
  done
  if [[ "${VERIFY_RELEASE:-0}" == "1" && "$found" == "0" ]]; then
    echo "VERIFY_RELEASE=1 but no V1 app bundle exists" >&2
    return 1
  fi
  if [[ "${VERIFY_RELEASE:-0}" == "1" && -d "$ROOT/NotchHub V1 Preview.app" ]]; then
    verify_bridge_keychain_entitlements "$ROOT/NotchHub V1 Preview.app"
  fi
  if [[ "${VERIFY_RELEASE:-0}" == "1" && -d "$ROOT/NotchHub.app" ]]; then
    verify_bridge_keychain_entitlements "$ROOT/NotchHub.app"
  fi
}

verify_bridge_keychain_entitlements() {
  local bundle="$1"
  local helper="$bundle/Contents/Helpers/NotchHubHookBridge"
  local entitlement_dir app_entitlements helper_entitlements app_group helper_group
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
  rm -rf -- "$entitlement_dir"
  [[ -n "$app_group" && "$app_group" == "$helper_group" &&
    "$app_group" == *.com.notchhub.v1.bridge ]]
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
run_gate "Available bundle signatures" verify_bundles

if [[ "${NOTCHHUB_TSAN:-0}" == "1" ]]; then
  run_gate "Thread sanitizer" swift test --sanitize=thread \
    --filter 'Bridge|Provider|Runtime|Integration'
fi

printf '\n'
if [[ "$FAIL" == "0" ]]; then
  echo "✅ V1 quality gate passed."
else
  echo "❌ V1 quality gate failed." >&2
fi
exit "$FAIL"
