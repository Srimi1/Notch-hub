#!/usr/bin/env bash
#
# NotchHub quality gate — runs the CLAUDE.md "Definition of Done" checks that are
# runnable in the current toolchain. Exits non-zero if any hard gate fails.
#
# Gates:
#   1. Build (debug)                 — must compile with zero errors
#   2. Build tests                   — test code must compile
#   3. SwiftFormat (--lint)          — formatting must be clean
#   4. Strict-concurrency report     — informational (legacy debt, see CLAUDE.md)
#   5. SwiftLint                      — only when full Xcode is available*
#   6. swift test                     — only when full Xcode is available*
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
SC=$(swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -c "warning:")
echo "  $SC strict-concurrency warnings (target: 0 — see CLAUDE.md Swift 6 migration)"

hr "5/6 SwiftLint"
if [[ "$HAS_XCODE" == "1" ]]; then
  if swift package --disable-sandbox --allow-writing-to-package-directory swiftlint; then
    echo "✓ lint clean"; else echo "✗ lint issues"; FAIL=1; fi
else
  echo "⊘ skipped — needs full Xcode (SourceKit). Command Line Tools only."
fi

hr "6/6 swift test"
if [[ "$HAS_XCODE" == "1" ]]; then
  if swift test; then echo "✓ tests pass"; else echo "✗ tests failed"; FAIL=1; fi
else
  echo "⊘ skipped — test runner needs full Xcode (XCTest). Test code still compiles (gate 2)."
fi

echo
if [[ "$FAIL" == "0" ]]; then echo "✅ Quality gate passed."; else echo "❌ Quality gate failed."; fi
exit "$FAIL"
