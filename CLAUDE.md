# CLAUDE.md - Autonomous App Architecture & Quality Gate

## Project Vision & Execution Style
- **Role**: You are the Lead Software Architect and Security Engineer. The human user will not write code; you are responsible for the entire codebase.
- **Strict Rule**: Never commit code that breaks compilation, skips error handling, or introduces insecure mock data.
- **Workflow**: For every feature, you must explicitly plan, write code, run automated tests, and perform the "Security & Quality Checklist" below before declaring a task complete.

## Core Development Commands
> **Project reality**: NotchHub is a **Swift Package** (`Package.swift`), not an Xcode
> workspace. Build/test/lint run through SwiftPM. SwiftLint and SwiftFormat are wired
> in as SwiftPM plugins (no Homebrew on this machine), so they run via `swift package`.

- **Quality gate (run before declaring done)**: `./scripts/check.sh`
- **Build (debug)**: `swift build`
- **Build & bundle the .app (release)**: `./scripts/build-app.sh` → produces `NotchHub.app`
- **Compile tests**: `swift build --build-tests`
- **Format (lint)**: `swift package --disable-sandbox --allow-writing-to-package-directory swiftformat Sources Tests --lint`
- **Format (apply)**: `swift package --disable-sandbox --allow-writing-to-package-directory swiftformat Sources Tests`
- **Strict-concurrency check**: `swift build -Xswiftc -strict-concurrency=complete`
- **Run the app**: `open NotchHub.app`

### Toolchain: full Xcode is installed — all gates run
`/Applications/Xcode.app` is installed and selected (`xcode-select -p` →
`/Applications/Xcode.app/Contents/Developer`, Swift 6.3.2). The full gate runs:
- **`swift test` executes.** The suite uses **swift-testing** (`import Testing`) and
  runs to completion (currently green). Test code also stays compilable via
  `swift build --build-tests`.
- **SwiftLint runs.** `.swiftlint.yml` is enforced. **Currently the lint gate is RED**
  on pre-existing debt — chiefly `ExpandedDashboardView.swift` exceeding the 700-line
  `file_length` limit (an `error`), plus assorted warnings (identifier names,
  force-unwraps). This is **deliberately deferred** (per Council ruling) and is not a
  regression from recent work; it surfaced the first time SwiftLint ever ran. Clear it
  in a dedicated cleanup pass, not piecemeal.
- **SwiftFormat** is clean and is part of every gate run.

`scripts/check.sh` auto-detects the toolchain and runs SwiftLint + `swift test` when
full Xcode is present (it is). If you ever switch to Command Line Tools only
(`sudo xcode-select -s /Library/Developer/CommandLineTools`), those two gates skip
automatically and build + build-tests + SwiftFormat carry the load.

### Swift 6 migration (tracked debt)
The package is on `swift-tools-version: 5.9` on purpose. Under complete strict
concurrency the existing code emits **~328 diagnostics** (down from ~456) that become
hard errors in the Swift 6 language mode (chiefly `SystemMonitorService` access to the
C global `vm_kernel_page_size`, plus non-`Sendable` closure captures). The CLAUDE.md backend
standard ("Swift 6 Strict Concurrency", "zero concurrency warnings") therefore applies
to **all new code** and is migrated into legacy files incrementally. Do not flip the
package to Swift 6 mode until the count is driven to zero — that would break the build
and violate the Strict Rule above. Track progress with the strict-concurrency check.

---

## 1. FRONTEND QUALITY ASSURANCE (SwiftUI / UX)
- **Native Mac Paradigms**: Do not write iOS layouts. Use native macOS sidebars (`NavigationSplitView`), custom toolbars, proper window padding (minimum 16pt), and strict keyboard shortcut mappings.
- **View Complexity Limits**: Never write a `body` property longer than 40 lines. Subdivide all complex layouts into smaller, modular sub-views or clean extensions to prevent Swift compiler timeout errors.
- **State Architecture**: Use the modern `@Observable` macro. Never mix state logic inside view layouts. Keep views purely data-driven.
- **Responsiveness**: All UI elements must dynamically resize. Test layouts at the minimum window size (`NSRect` bounds) and full screen.

## 2. BACKEND & DATA ARCHITECTURE (Swift 6)
- **Strict Concurrency**: Enforce Swift 6 Strict Concurrency. All data fetches, network layers, and persistence operations must run on isolated actors or background threads. UI updates must be globally isolated to `@MainActor`.
- **Robust Error Routing**: Never use empty `catch {}` blocks or silent `try?`. All errors must be explicitly typed, logged to a telemetry console, and gracefully bubbled up to a user-facing visual alert.
- **Offline & Persistence**: If using SwiftData or CoreData, ensure strict schema versioning and explicit migration paths. Never block the main thread during data initialization.
- **API Resilience**: Network requests must implement intelligent timeout limits (max 15s), automatic retry logic for transient failures (status 503), and robust offline handling.

## 3. COMPREHENSIVE SECURITY GATE
- **Credential Safety**: Never hardcode API keys, tokens, or encryption secrets in the repository. Use macOS `Keychain` for user secrets and `.xcconfig` files read at build time for environment variables.
- **App Sandbox Optimization**: Restrict entitlements strictly to what the app requires. If internet or file access is needed, request the absolute minimum required permissions in the `.entitlements` file.
- **Data at Rest**: Encrypt sensitive user data locally using `CryptoKit` before saving to disk or databases.
- **Data in Transit**: Enforce strict Application Security (ATS). Use TLS 1.3 for all backend communication and implement SSL Pinning for high-security endpoints.
- **Input Sanitization**: Treat all external data (API payloads, user text fields, deep-link URLs) as untrusted. Strictly validate and sanitize inputs to prevent injection or app crashing.

---

## AI Definition of Done (DoD)
Before asking the user to review a feature, you must verify:
1. The app builds with zero errors and zero concurrency warnings.
2. The code passes through `swiftlint` and `swiftformat` without warnings.
3. You have simulated at least one backend failure mode (e.g., offline state) and confirmed the app handles it securely without crashing.
