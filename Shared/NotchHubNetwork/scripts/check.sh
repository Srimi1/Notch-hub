#!/usr/bin/env bash

set -uo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$PACKAGE_ROOT/../.." && pwd)"
FAILURES=0

cd "$PACKAGE_ROOT"

run_gate() {
    local label="$1"
    shift
    printf '\n▸ %s\n' "$label"
    if "$@"; then
        printf '✓ %s\n' "$label"
    else
        printf '✗ %s\n' "$label"
        FAILURES=1
    fi
}

find_repository_tools() {
    SWIFT_FORMAT_BIN="$REPOSITORY_ROOT/.build/checkouts/SwiftFormat/CommandLineTool/swiftformat"
    SWIFT_LINT_BIN="$REPOSITORY_ROOT/.build/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint"
    if [[ ! -x "$SWIFT_FORMAT_BIN" || ! -x "$SWIFT_LINT_BIN" ]]; then
        swift package --package-path "$REPOSITORY_ROOT" resolve >/dev/null
    fi
}

run_security_scan() {
    local forbidden_runtime='URLSession|NWConnection|Process[[:space:]]*\(|NSTask|posix_spawn|AuthorizationExecuteWithPrivileges'
    local credential_literal='(api[_-]?key|access[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*"[^\"]+"'

    if rg -n --glob '*.swift' "$forbidden_runtime" Sources; then
        printf 'Forbidden outbound-request or helper-process API found.\n' >&2
        return 1
    fi
    if rg -n -i --glob '*.swift' "$credential_literal" Sources; then
        printf 'Possible hard-coded credential found.\n' >&2
        return 1
    fi
    if rg -n '\.package[[:space:]]*\(' Package.swift; then
        printf 'The shared package must not add external dependencies.\n' >&2
        return 1
    fi
    if find Sources -name '*.entitlements' -print -quit | rg -q .; then
        printf 'The passive reader must not add entitlements.\n' >&2
        return 1
    fi
}

run_format_lint() {
    if [[ ! -x "$SWIFT_FORMAT_BIN" ]]; then
        printf 'SwiftFormat executable was not resolved from the repository package.\n' >&2
        return 1
    fi
    "$SWIFT_FORMAT_BIN" Sources Tests --config .swiftformat --lint
}

run_swift_lint() {
    if [[ ! -x "$SWIFT_LINT_BIN" ]]; then
        printf 'SwiftLint executable was not resolved from the repository package.\n' >&2
        return 1
    fi
    "$SWIFT_LINT_BIN" lint --config .swiftlint.yml --strict --quiet
}

find_repository_tools
run_gate "Strict-concurrency build" \
    swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
run_gate "Swift tests" \
    swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
run_gate "SwiftFormat lint" run_format_lint
run_gate "SwiftLint" run_swift_lint
run_gate "Passive-reader security scan" run_security_scan

printf '\n'
if [[ "$FAILURES" == "0" ]]; then
    printf '✅ NotchHubNetwork quality gate passed.\n'
else
    printf '❌ NotchHubNetwork quality gate failed.\n'
fi
exit "$FAILURES"
