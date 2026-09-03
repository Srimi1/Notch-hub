# NotchHub V1 Implementation Record

## Goal

Build an independent Swift 6, macOS 14+ NotchHub application whose first
milestone is a working AI Command Center for Codex and Claude. The legacy
package remains buildable and is not a dependency of V1.

## Milestones

- **0.8:** Provider-neutral usage models, Codex and Claude discovery, quota
  ingestion, sanitized session events, one-time approvals, a combined menu-bar
  meter, and an adaptive notch interface.
- **0.9:** Audited Dashboard, Media, Clipboard, and Focus ports; migration,
  onboarding, signed direct updates, and the sandbox-safe Lite target.
- **1.0:** Accessibility, performance baselines, security review, universal
  packaging, notarization, and App Store submission readiness.

Model-price catalogs and calculated token costs are excluded. Only
provider-reported quota, reset, and credit information belongs in V1.

## Architecture

- `NotchHubCore`: Sendable domain models, actor-isolated coordination,
  executable discovery, encrypted snapshots, and application state.
- `NotchHubBridge`: Narrow, UI-free hook schemas, authenticated transport, and
  configuration planning shared by the app and relay helper.
- `NotchHubV1`: direct-distribution AppKit/SwiftUI application.
- `NotchHubLite`: sandbox-compatible application with no CLI or hook access.
- `NotchHubHookBridge`: bounded command-hook relay for Codex and Claude.
- Tests use temporary homes and fixture adapters; they never inspect real user
  credentials, settings, or provider transcripts.

## Quality Gate

The V1 gate builds every product, compiles and runs tests, lints formatting,
enforces complete strict concurrency with warnings as errors, scans tracked V1
content for credential patterns, and optionally runs process tests under TSan.
No milestone is complete while the V1 gate or the legacy root gate is red.

## Security Invariants

- Never persist prompts, model output, complete commands, transcripts, email
  addresses, or provider credentials.
- A missing, invalid, or timed-out bridge response abstains from the provider
  decision; it can never imply approval.
- One actor owns each child process and every associated descriptor for its
  entire lifetime.
- Existing CLI configuration is merged atomically and only uniquely owned
  NotchHub entries may be removed.
- External strings are bounded and sanitized before display or logging.

## Implementation Order

1. Independent package, gates, typed domain, fixture adapters, and adaptive UI.
2. Secure bridge transport and consent-based hook configuration.
3. Official Codex App Server and Claude hook/status-line adapters.
4. Audited essential modules, migration, updates, and Lite capability split.
5. Benchmarks, release signing, accessibility audit, and 1.0 hardening.

## 2026-09-03 Continuation Plan

The recovered implementation is checkpointed before further work. Resume the
interrupted 0.9 foundation in this order:

1. Complete the sandbox-safe Dashboard, Clipboard, and Focus models and views
   in `NotchHubSafeFeatures`; make `NotchHubLite` depend only on that module.
2. Add focused Swift Testing coverage for safe-feature state transitions,
   clipboard bounds, timer completion, and invalid input handling.
3. Restore clean compilation, SwiftFormat, SwiftLint, strict-concurrency, and
   credential-scan results without suppressing rules or weakening safeguards.
4. Run the V1 offline failure simulation, complete V1 quality gate, optional
   descriptor-sensitive tests, app-bundle builds, and the legacy root gate.
5. Review the final diff against the security invariants above before treating
   the recovered 0.8/0.9 foundation as ready for the next product slice.

## 2026-09-03 Continuation Result

- Implemented reusable Dashboard, opt-in Clipboard, and Focus experiences for
  Direct and Lite, with focused state, bounds, privacy, and failure tests.
- Split the hook relay onto the UI-free `NotchHubBridge` target and hardened
  bundle checks for Sparkle linkage, sandbox entitlements, and helper isolation.
- Passed the V1 gate with 158 tests in 26 suites, the descriptor-sensitive TSan
  run with 55 tests in 9 suites, and the legacy gate with 343 tests in 60 suites.
- Built universal Direct and Lite release bundles; both passed signature,
  linkage, entitlement, helper-isolation, and five-second launch smoke checks.

## 2026-09-03 Rejected Preview Candidate — Never Published

This candidate was superseded before any commit, tag, push, or GitHub upload.
Its artifact and checksum below are retained only as a rejection record and
must never be used for a release.

- Added a release-only universal DMG pipeline with immutable output handling,
  mounted-image verification, exact code-signing identity checks, full nested
  Mach-O architecture validation, and a verified SHA-256 sidecar.
- Added truthful bridge startup states: a missing shared-Keychain entitlement
  disables session setup, while transient startup failures offer an explicit
  retry without weakening provider-native prompts.
- Passed the V1 quality gate with 160 tests in 26 suites, including the offline
  failure simulation, zero SwiftLint or SwiftFormat violations, and complete
  strict concurrency with warnings treated as errors.
- Passed the descriptor-sensitive Thread Sanitizer run with 57 tests in 10
  suites and the legacy root gate with 343 tests in 60 suites.
- Mounted and launched the packaged app, then visually verified Agents,
  Dashboard, opt-in Clipboard, Focus, the Media placeholder, and the disabled
  bridge state.
- Produced `NotchHub-V1-Preview-0.8.0-universal.dmg` with SHA-256
  `e358c24720e99cdad113b192b98b17728e25e34f5d6d6803c473bb394efb6659`.

## 2026-09-04 Compact Overlay Redesign

The first preview candidate is rejected and must not be published. Its
`680 x 520` detail panel and `680 x 620` approval panel do not follow the
small, shallow overlay language established by NotchHub 0.5 through 0.7.

The replacement design uses the legacy overlay as its measurable baseline:

1. Restore the exact physical-notch idle geometry, with a `190 x 32` fallback
   and optional 112-point activity wings.
2. Use `860 x 136` as the interactive dashboard baseline, expanding only to
   clear a taller physical notch or narrowing to fit the display. Keep a
   32-point module band and one 68-point content row.
3. Remove duplicate titles, stacked cards, empty sections, and the unfinished
   Media tab. Preserve its enum case only for decoding compatibility while
   rejecting selection and stripping it from migrated visible capabilities.
4. Render Agents, Dashboard, Clipboard, Focus, bridge status, and approvals in
   bounded single-row variants; an approval replaces the Agents row instead
   of making the panel taller.
5. Re-run format, lint, Swift 6 concurrency, tests, offline failure handling,
   release packaging, and mounted-app visual smoke checks before creating a
   new DMG or publishing anything.

## 2026-09-04 Compact Overlay Result

- Replaced the rejected 680-by-520/620 window-like interface with the 0.5-0.7
  overlay proportions: exact physical-notch idle geometry, a 190-by-32 fallback,
  conditional 112-point wings, and an 860-by-136 shallow dashboard baseline.
- Added bounded screen-metric validation, top-edge frame policy, hover-event
  gating during resize, settled-pointer reconciliation, and peer-overlay
  yielding. Pinning the ribbon no longer explicitly takes keyboard focus.
- Reduced each module to one 68-point content row. Approvals replace that row;
  “Allow once” appears only inside a downward-opening popover that shows the
  complete sanitized action detail.
- Added truthful approval, session, focus, and provider wing states. Provider
  cards show compact reset timing and an exact reset timestamp in their help.
- Passed 170 V1 tests in 29 suites, 58 Thread Sanitizer tests in 11 suites, and
  343 legacy tests in 60 suites. V1 SwiftLint reports zero violations,
  SwiftFormat is clean, strict Swift 6 concurrency passes with warnings as
  errors, and the explicit offline failure simulation passes.
- Built and mounted the 5,051,073-byte universal ad-hoc preview DMG. Mounted UI
  smoke passed Agents, Dashboard, Clipboard-off, Focus start, activity wings,
  hover re-entry/collapse, and the approval review popover.
- Release artifact SHA-256:
  `4b62caf6e6173e0c2c84061476cac254cf5d2ffd7452baf2a33b425a8f1149c2`.
