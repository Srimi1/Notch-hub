# NotchHub — Progress & Status

_Last updated: 2026-05-31 · Personal daily-driver macOS notch-overlay app (MacNotch alternative)._

---

## ✅ Done

### App core (built earlier)
- **Overlay engine** — collapsed notch-sized pill expands to a dashboard on hover/click; AppKit `NSPanel` + SwiftUI content, notch geometry detection, live-activity wings when collapsed.
- **Services layer** — 9 real services via `ServiceHub`: Time, SystemMonitor (CPU/RAM/disk), Battery (IOKit), Media (Music/Spotify), Calendar (EventKit), Clipboard, Focus/DND, MemoryCleaner (official `purge`), AICoding.
- **7 working modules** rendering live data: Dashboard, Media, Calendar, AI Coding, Clipboard, Focus, RAM Cleaner.

### App icon
- Blue notch-cutout icon generated from source art → `Resources/AppIcon.icns` (+ transparent master `AppIcon-1024.png`), wired into `Info.plist` + `build-app.sh`. Applied to the live bundle.

### Tooling / quality gates
- **SwiftPM plugins** wired (no Homebrew needed): SwiftLint (`SimplyDanny/SwiftLintPlugins`) + SwiftFormat (`nicklockwood/SwiftFormat`), with `.swiftlint.yml` + `.swiftformat` configs.
- **Test target** `Tests/NotchHubTests` using **swift-testing** (`import Testing`), framework paths/rpaths wired for Command-Line-Tools.
- **`scripts/check.sh`** quality gate — runs build + build-tests + SwiftFormat + strict-concurrency report; auto-detects Xcode and runs SwiftLint + `swift test` only when present.
- Codebase formatted to a clean baseline.

### MVP product shell (2026-05-30, planned via Council)
Decisions: audience = **personal daily-driver**; scope = **shell + finish AICoding**.
1. **`Core/ModulePreferences.swift`** — `UserDefaults` persistence for visible modules + last active module, validated against `FeatureModule.allCases` on load (survives enum renames). No SwiftData.
2. **Module customization** — dashboard reads visibility from prefs; restores last-viewed module on launch.
3. **Status-menu settings** — "Modules" submenu (per-module checkboxes) + "Launch at Login" (`SMAppService`).
4. **Permissions cleanup** — removed unused Bluetooth declaration from `Info.plist`; Focus module now warns proactively via `AXIsProcessTrusted()` instead of failing silently.
5. **AI Coding honesty** — removed fabricated budget numbers + fake `ai_limits.json` seeding; shows "No data" until the real hook file exists (schema documented inline).

**Quality:** `./scripts/check.sh` green · 0 new strict-concurrency warnings (legacy count dropped 456 → 438) · release `.app` builds, signs, launches.

---

## 🔲 Left to do

### Interactive verification (owed — can't be automated here, see Xcode note)
- [ ] Module toggle survives Quit → relaunch.
- [ ] Launch-at-login appears in **System Settings ▸ General ▸ Login Items** and survives reboot.
- [ ] Focus module shows "Accessibility permission needed" when not granted.
- [ ] AI Coding shows "No data" with no/empty `~/.cache/hermes-notify/ai_limits.json`.

### Feature/integration backlog
- [ ] **`hermes-notify` hook-side writer** — make the hook system write real usage into `ai_limits.json` and consume `approval_response.json`. This is a cross-system task *outside* the Swift app; the app is now honest and ready for it.
- [ ] Verify/tune the Focus DND AppleScript on-device (Control Center element matching varies by macOS version).
- [ ] Now-playing via `mediaremote-adapter` helper; notifications / weather modules.

### Swift 6 migration (tracked debt)
- [ ] ~438 strict-concurrency warnings become hard errors under Swift 6 language mode (mostly `SystemMonitorService` C-global `vm_kernel_page_size` + non-`Sendable` captures). Package stays on `swift-tools-version: 5.9` until migrated. **All new code is written Swift-6-clean** so the count only goes down.

---

## ⚠️ The Xcode situation (important)

**This machine has Command Line Tools only — no full `Xcode.app` installed.** That blocks two dev tools (it does **not** block building, running, or shipping the app — the `.app` builds, signs ad-hoc, and runs fine):

| Capability | Works on CLT? | Why |
|------------|---------------|-----|
| `swift build` / `./scripts/build-app.sh` / run the app | ✅ Yes | pure SwiftPM + ad-hoc codesign |
| SwiftFormat | ✅ Yes | pure-Swift, no SourceKit |
| **`swift test` (execution)** | ❌ No | XCTest is absent; the swift-testing runner doesn't execute under CLT — the test bundle *builds* but no tests run (exit 0 is meaningless). Test code is kept valid via `swift build --build-tests`. |
| **SwiftLint** | ❌ No | needs SourceKit in an Xcode layout; under CLT it crashes loading `sourcekitdInProc`. Config is ready and works once Xcode is present. |

### Clarification on cost
- **Xcode is free** from the Mac App Store. A **normal (free) Apple ID** downloads it — **no paid Apple Developer account ($99/yr) is required** to build, run, test, or locally sign the app. The paid account is only for App Store / TestFlight distribution.
- **User has decided not to install Xcode.** That's fine — the app is fully usable without it.

### What that means going forward
- **Live gates on this machine:** build + build-tests (compile) + SwiftFormat + strict-concurrency report — run via `./scripts/check.sh`.
- **Test execution & SwiftLint** stay shelved; they'd light up automatically (`check.sh` detects Xcode) **if** Xcode is ever installed, or in CI with Xcode.
- **Verification is manual** — run the app (`./scripts/build-app.sh && open NotchHub.app`) and use the interactive checklist above. That manual checklist *is* the test plan until a runner is available.
- **Optional alternative if test execution is ever wanted without Xcode:** build a CLT-native test runner (a small executable target that runs assertions and exits non-zero on failure). Not started — offered, not blocking.

---

## How to build & run

```bash
./scripts/build-app.sh        # release build → NotchHub.app (ad-hoc signed)
open NotchHub.app             # launch
./scripts/check.sh            # quality gate (build + tests-compile + format + concurrency)
```

Reference plan: `~/.claude/plans/let-us-first-plan-groovy-backus.md`.
