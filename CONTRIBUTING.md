# Contributing to NotchHub

Thanks for your interest! NotchHub is a small, personal macOS app, but
contributions are welcome.

## Prerequisites

- macOS with a Swift toolchain (Xcode or Command Line Tools).
- It's a **Swift Package** (`Package.swift`), not an Xcode project — everything
  runs through `swift` / `swift package`.

## Development loop

```bash
swift build                  # debug build
swift test                   # run the test suite (swift-testing)
./scripts/build-app.sh       # build the release NotchHub.app (ad-hoc signed)
open NotchHub.app            # run it
./scripts/check.sh           # full quality gate (run before opening a PR)
```

`./scripts/check.sh` runs: build, build-tests, SwiftFormat (lint),
strict-concurrency report, SwiftLint, and `swift test`. It auto-detects whether
full Xcode is installed and skips Xcode-only gates otherwise.

## Code standards

- **Format with SwiftFormat** — `swift package --disable-sandbox --allow-writing-to-package-directory swiftformat Sources Tests`. CI lints formatting.
- **New code must be Swift 6 strict-concurrency clean.** The package is pinned to
  `swift-tools-version: 5.9` while legacy concurrency debt is migrated incrementally
  — don't add new warnings.
- **No silent failures** — avoid empty `catch {}` and silent `try?`; log errors.
- **Keep files focused** (aim < 500 lines) and SwiftUI `body` blocks small.
- **Add tests** for new logic where practical (see `Tests/NotchHubTests`).

### Known accepted debt

- `Sources/NotchHub/UI/ExpandedDashboardView.swift` exceeds the SwiftLint
  `file_length` cap (tracked; splitting it is welcome).
- ~328 strict-concurrency warnings in legacy files (Swift 6 migration in progress).

## Pull requests

1. Branch off `main`.
2. Make focused changes; run `./scripts/check.sh` and ensure tests pass.
3. Fill in the PR template. CI must be green before merge.

## Reporting bugs / requesting features

Use the issue templates. For **security** issues, follow [SECURITY.md](SECURITY.md)
instead of opening a public issue.
