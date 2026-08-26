#!/usr/bin/env bash
#
# NotchHub repository quality gate. Exits non-zero if any hard gate fails.
#
# Gates:
#   1. Build (debug)                 — must compile with zero errors
#   2. Build tests                   — test code must compile
#   3. SwiftFormat (--lint)          — formatting must be clean
#   4. Strict-concurrency report     — informational during the Swift 6 migration
#   5. SwiftLint                      — only when full Xcode is available*
#   6. swift test                     — only when full Xcode is available*
#   7. Thread sanitizer (opt-in)      — NOTCHHUB_TSAN=1 only; adapter suite
#
# *SwiftLint needs SourceKit and the test runner needs XCTest; both require full
#  Xcode. With Command Line Tools only, these are skipped (not failed) and the
#  build/format gates carry the load. Install Xcode + `sudo xcode-select -s
#  /Applications/Xcode.app` to enable them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SF="swift package --disable-sandbox --allow-writing-to-package-directory swiftformat"
FAIL=0
hr() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# A "full Xcode" toolchain (not bare Command Line Tools) is needed for SourceKit
# (SwiftLint) and XCTest (swift test).
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
HAS_XCODE=0
[[ "$DEVDIR" == *"/Xcode"*".app/"* ]] && HAS_XCODE=1

hr "1/6 Build (debug)"
if swift build; then echo "✓ build ok"; else echo "✗ build failed"; FAIL=1; fi

hr "2/6 Build tests"
if swift build --build-tests; then echo "✓ tests compile"; else echo "✗ test compile failed"; FAIL=1; fi

hr "3/6 SwiftFormat (lint)"
if $SF Sources Tests --lint; then echo "✓ formatting clean"; else echo "✗ formatting issues — run: $SF Sources Tests"; FAIL=1; fi

hr "4/6 Strict-concurrency (informational — legacy debt)"
swift package clean >/dev/null 2>&1 || true
# Scoped to our own sources on purpose. The flag applies to every target in the
# graph, so an unscoped count would be dominated by the Lottie dependency and
# stop being a number about NotchHub's migration debt.
SC=$(swift build -Xswiftc -strict-concurrency=complete 2>&1 \
  | grep "warning:" | grep -c "Sources/NotchHub/" || true)
echo "  $SC strict-concurrency warnings in Sources/NotchHub (target: 0)"

hr "5/6 SwiftLint"
if [[ "$HAS_XCODE" == "1" ]]; then
  if swift package --disable-sandbox --allow-writing-to-package-directory swiftlint; then
    echo "✓ SwiftLint completed"; else echo "✗ lint issues"; FAIL=1; fi
else
  echo "⊘ skipped — needs full Xcode (SourceKit). Command Line Tools only."
fi

hr "6/6 swift test"
if [[ "$HAS_XCODE" == "1" ]]; then
  if swift test; then echo "✓ tests pass"; else echo "✗ tests failed"; FAIL=1; fi
else
  echo "⊘ skipped — test runner needs full Xcode (XCTest). Test code still compiles (gate 2)."
fi

# Opt-in: rebuild the adapter suite under the thread sanitizer. Off by default
# because the sanitizer forces a full rebuild and a slower run; the descriptor
# ownership it checks lives in AdapterProcess, so only that suite runs.
if [[ "${NOTCHHUB_TSAN:-0}" == "1" && "$HAS_XCODE" == "1" ]]; then
  hr "7 (opt-in) swift test --sanitize=thread"
  if swift test --sanitize=thread --filter AdapterProcessLauncherTests; then
    echo "✓ TSan clean"; else echo "✗ TSan findings"; FAIL=1; fi
fi

echo
if [[ "$FAIL" == "0" ]]; then echo "✅ Quality gate passed."; else echo "❌ Quality gate failed."; fi
exit "$FAIL"
