# NotchHub V1 Preview 0.8.2

This prerelease continues the independent NotchHub V1 line for macOS 14 and
newer. It does not replace the current stable NotchHub release.

## Included

- The same compact Media row and collapsed playback wing used by NotchHub
  0.6.0: a 56-point astronaut tile, one-line title and artist labels, and three
  30-point previous, play/pause, and next controls inside the existing shallow
  860-by-136-point V1 ribbon.
- A Network tab with passive per-second download and upload traffic across
  all apps on the active interface. Counters are read only while the tab is
  visible in the expanded ribbon, need no permission, and keep no history;
  Mbps is the default unit and MB/s is available from the tab's picker. It
  is backed by the local `NotchHubNetwork` package, adapted from
  Internet-speed-reader (Apache 2.0) with its license and notice bundled.
- System-wide now-playing metadata and controls in the Direct edition through
  the bundled MediaRemote adapter. Music and Spotify Apple Events support is
  activated only after Media is opened and provides an interaction fallback.
- Private Codex quota and reset monitoring through the locally installed
  official Codex CLI and its existing sign-in state.
- Local Dashboard metrics, opt-in in-memory Clipboard history, and a local
  Focus timer.
- A universal app containing native `arm64` and `x86_64` binaries.

CodexBar is not integrated or bundled. No CodexBar source, binary, or runtime
is included.

## Preview limitations

- This artifact is ad-hoc signed and not notarized because a Developer ID
  identity and notarization profile were not available on the build machine.
  A normal Gatekeeper assessment is expected to block the first launch. Verify
  the published SHA-256 checksum, then use Finder's **Open** action or macOS
  **Privacy & Security > Open Anyway** only if you downloaded the DMG from this
  release.
- The Media and Network features are available only in the Direct preview.
  The Lite edition intentionally excludes the adapter, the network module,
  Lottie, animation, Apple Events access, and associated resources.
- The terminal-session and approval bridge is intentionally unavailable in
  this build because a provisioned shared Keychain group is required. Claude
  status-line usage ingestion depends on that bridge and is unavailable too.
- Updates are manual; this preview has no configured Sparkle update feed.
- The Codex and Claude CLIs are separate installations. NotchHub does not
  install them or store their credentials.
- Quit the stable NotchHub app while testing this preview; two top-edge overlay
  versions running together will occupy the same notch.

Provider credentials remain with the official CLIs. NotchHub V1 does not
persist prompts, model output, complete commands, or transcript contents.

## Verification

- File: `NotchHub-V1-Preview-0.8.2-universal.dmg`
- Size: 8,154,204 bytes
- SHA-256:
  `63452d17e84a69df75af2a02875022149575dc584a27bc7c1487809caa577598`
