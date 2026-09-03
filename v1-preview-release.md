# NotchHub V1 Preview Release Plan

## Objective

Ship the current independent NotchHub V1 implementation as an honest preview
release without changing the existing stable `v0.6.0` release. Publish the
source branch and a verified universal DMG to the configured GitHub repository.

## Release Identity

- Product: NotchHub V1 Preview
- App version: `0.8.0` (existing bundle metadata)
- Git tag: `v1-preview-0.8.0`
- GitHub release type: prerelease
- CodexBar is not integrated or bundled; no CodexBar source, binary, or runtime
  is included.

## Work Plan

1. Audit the V1 product and release surface for correctness, privacy, licensing,
   versioning, and known incomplete features.
2. Add a V1-specific DMG builder that creates a drag-to-Applications image,
   validates the mounted payload, verifies code signatures and architectures,
   emits a SHA-256 checksum, and supports optional notarization when credentials
   exist.
3. Add automated packaging checks and release documentation without weakening
   existing Swift build, test, lint, strict-concurrency, or security gates.
4. Build the universal Direct preview app and DMG. Verify the app bundle, helper
   isolation, Sparkle linkage, DMG contents, checksum, and launch stability.
5. Run `V1/scripts/check.sh`, the opt-in TSan gate, and the legacy root gate.
6. Review and commit only intended changes, push `codex/v1-resume`, create tag
   `v1-preview-0.8.0`, and publish a GitHub prerelease with the DMG and checksum.
7. Confirm the public branch, tag, release page, and downloadable asset before
   reporting completion.

## Release Boundaries

- This is a preview, not the final V1. Media is not exposed in this preview,
  and guided onboarding remains incomplete; both must be named in the release
  notes.
- Do not merge to `main` or replace the latest stable release.
- Do not publish secrets, local paths, provider data, prompts, transcripts, or
  signing credentials.
- If Developer ID/notarization credentials are unavailable, publish only with a
  clear Gatekeeper warning and preserve the prerelease label.

## Definition of Done

- All project gates pass with no new lint, format, concurrency, or security
  failures.
- A universal DMG can be mounted and contains the expected signed app plus an
  `/Applications` shortcut.
- The release artifact checksum matches the uploaded asset.
- The source branch and prerelease are visible in `Srimi1/Notch-hub` and the
  existing stable release remains unchanged.

## Compact Candidate Verification

- V1 quality gate: passed with 170 tests in 29 suites, one explicit offline
  failure simulation, zero SwiftLint violations, clean SwiftFormat, complete
  Swift 6 strict concurrency with warnings as errors, credential scanning, and
  fresh Direct/Lite app packaging.
- Thread Sanitizer: passed 58 descriptor-sensitive tests in 11 suites.
- Legacy root gate: passed 343 tests in 60 suites; the root package retained
  only its pre-existing informational concurrency and lint debt.
- Universal DMG: 5,051,073 bytes; every regular Mach-O contains arm64 and
  x86_64 slices. SHA-256:
  `4b62caf6e6173e0c2c84061476cac254cf5d2ffd7452baf2a33b425a8f1149c2`.
- Signing: valid ad-hoc signatures; no Developer ID identity, notarization
  ticket, or shared-Keychain entitlement is present. Gatekeeper rejection is
  expected and disclosed.
- Mounted release smoke: passed Agents, Dashboard, Clipboard-off, Focus start,
  compact active-timer wings, hover re-entry, delayed collapse, and clean quit.
  A source-identical isolated UI harness also verified that the approval row
  opens its complete review popover downward without increasing ribbon height.
- Geometry tests cover physical-notch, notchless, partial/implausible screen
  metrics, top-edge centering, 860-by-136 baseline expansion, and narrow-display
  clamping. Media is absent from navigation and rejected by selection policy.
- After upload, re-download both assets and verify this checksum before marking
  the prerelease complete.
