# NotchHub V1 Preview 0.8.0

This prerelease is an early, independent NotchHub V1 build for macOS 14 and
newer. It does not replace the current stable NotchHub release.

## Included

- Private Codex quota and reset monitoring through the locally installed
  official Codex CLI and its existing sign-in state.
- A native top-edge surface based on NotchHub 0.5-0.7: physical-notch idle
  geometry, small activity wings, and a shallow 860-by-136-point dashboard
  baseline that narrows for smaller displays.
- Local Dashboard metrics, opt-in in-memory Clipboard history, and a local
  Focus timer.
- A universal app containing native `arm64` and `x86_64` binaries.

CodexBar informed behavior and performance research for this preview, but it
is not integrated or bundled. No CodexBar source, binary, or runtime is
included.

## Preview limitations

- This artifact is ad-hoc signed and not notarized because a Developer ID
  identity and notarization profile were not available on the build machine.
  A normal Gatekeeper assessment is expected to block the first launch. Verify
  the published SHA-256 checksum, then use Finder's **Open** action or macOS
  **Privacy & Security > Open Anyway** only if you downloaded the DMG from this
  release.
- The terminal-session and approval bridge is intentionally unavailable in
  this build because a provisioned shared Keychain group is required. Claude
  status-line usage ingestion depends on that bridge and is unavailable too.
- Media is not exposed in this preview, and guided onboarding is not complete.
- Updates are manual; this preview has no configured Sparkle update feed.
- The Codex and Claude CLIs are separate installations. NotchHub does not
  install them or store their credentials.
- Quit the stable NotchHub app while testing this preview; two top-edge overlay
  versions running together will occupy the same notch.

Provider credentials remain with the official CLIs. NotchHub V1 does not
persist prompts, model output, complete commands, or transcript contents.

## Verification

- File: `NotchHub-V1-Preview-0.8.0-universal.dmg`
- Size: 5,051,073 bytes
- SHA-256:
  `4b62caf6e6173e0c2c84061476cac254cf5d2ffd7452baf2a33b425a8f1149c2`
