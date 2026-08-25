# Contributing to NotchHub

NotchHub is an independently maintained native macOS app. Focused contributions
are welcome.

## Prerequisites

- macOS 14 or later
- Git
- Xcode or the Swift Command Line Tools

NotchHub uses Swift Package Manager and has no Xcode project. Build and tooling
commands run through `swift` and `swift package`. The Command Line Tools can build
the app and compile its tests. Full Xcode is required to run SwiftLint and the
test suite locally.

## Development loop

```bash
swift build
swift test
./scripts/build-app.sh release
open NotchHub.app
./scripts/check.sh
```

The app build uses an available Apple Development or Developer ID certificate
and falls back to ad-hoc signing when no identity is available.

`./scripts/check.sh` builds the app and tests, checks SwiftFormat, and reports
strict-concurrency warnings. With full Xcode selected, it also runs SwiftLint
and the test suite. The Xcode-only checks are skipped when only the Command Line
Tools are installed.

## Code standards

- **Format with SwiftFormat:**
  `swift package --disable-sandbox --allow-writing-to-package-directory swiftformat Sources Tests`.
  CI checks formatting.
- **New code must be Swift 6 strict-concurrency clean.** The package is pinned to
  `swift-tools-version: 5.9` while legacy concurrency debt is migrated incrementally
  so new warnings must not be added.
- **Do not hide failures.** Avoid empty `catch {}` blocks and silent `try?` calls;
  log errors or surface them in the interface.
- **Keep files focused** (aim < 500 lines) and SwiftUI `body` blocks small.
- **Add tests** for new logic where practical (see `Tests/NotchHubTests`).
- **Keep public claims current.** Update the README, security policy, architecture
  guide, and [changelog](CHANGELOG.md) when behavior, permissions, or local data
  handling changes.

## Pull requests

1. Branch off `main`.
2. Make one focused change and add tests where the behavior can be isolated.
3. Run `./scripts/check.sh`. Record any Xcode-only check you could not run.
4. Include a screenshot or short recording for visible interface changes.
5. Fill in the pull request template. CI must pass before merge.

## Reporting bugs / requesting features

Use the issue templates for bugs and feature requests. Report security issues
through the private process in [SECURITY.md](SECURITY.md).
