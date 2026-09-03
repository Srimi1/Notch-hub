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
