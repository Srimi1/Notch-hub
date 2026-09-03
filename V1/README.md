# NotchHub V1

NotchHub V1 is an independent Swift 6 application focused on a private,
notch-native AI command center for Codex and Claude. The legacy NotchHub package
at the repository root remains separate and buildable.

## Development

```sh
cd V1
swift build
swift test
./scripts/check.sh
```

The direct app is `NotchHubV1`, the sandbox-compatible edition is
`NotchHubLite`, `NotchHubBridge` is the UI-free bridge protocol library, and
`NotchHubHookBridge` is the bounded command-hook relay.

Build runnable app bundles with:

```sh
./scripts/build-app.sh direct debug
./scripts/build-app.sh lite debug
```

## Preview DMG

Create the universal Direct preview DMG and its SHA-256 sidecar with:

```sh
./scripts/build-dmg.sh release
```

The default artifacts are written to `dist/` as
`NotchHub-V1-Preview-<version>-universal.dmg` and the matching `.dmg.sha256`
file. The builder checks the app signature, arm64 and x86_64 slices, Sparkle
linkage, hook-helper isolation, the mounted payload, the `/Applications`
shortcut, and the repository's Apache-2.0 `LICENSE` before publishing either
file.

Without a Developer ID identity, the builder requires a clean ad-hoc app and
helper signature with no Team ID or shared keychain entitlement. This local
preview is launchable for testing, but normal Gatekeeper assessment is expected
to block it on another Mac until the user explicitly approves it.
For a distributable build, configure a Developer ID Application certificate
and a `notarytool` keychain profile:

```sh
NOTCHHUB_SIGNING_IDENTITY="Developer ID Application: … (TEAMID)" \
NOTCHHUB_TEAM_ID="TEAMID" \
NOTCHHUB_NOTARY_PROFILE="NotchHubNotary" \
./scripts/build-dmg.sh release
```

When the notary profile is supplied, the builder submits the DMG, staples the
ticket, and requires Gatekeeper acceptance. `--skip-build` is available only
for packaging an existing, already-verified universal preview app.

Direct beta bundles use `com.notchhub.v1.preview`. An official 1.0 package is
enabled only by an explicit release build with a Developer ID identity, HTTPS
Sparkle feed, and EdDSA public key:

```sh
NOTCHHUB_RELEASE=1 NOTCHHUB_OFFICIAL_RELEASE=1 \
NOTCHHUB_SIGNING_IDENTITY="Developer ID Application: …" \
NOTCHHUB_UPDATE_FEED_URL="https://…/appcast.xml" \
NOTCHHUB_UPDATE_PUBLIC_KEY="…" \
./scripts/build-app.sh direct release
```

The direct app discovers provider CLIs in bounded standard locations and uses
their existing sign-in state. It does not install a CLI. Session hooks are
previewed before configuration changes, preserve existing entries, and can
remove only entries owned by NotchHub V1. Store Lite never links the hook or
provider runtime.

Provider credentials stay with the official CLIs. V1 never persists prompts,
model output, complete commands, or transcript contents.

## Preview Status

The ad-hoc `0.8.0` preview includes Codex usage plus the Dashboard, opt-in
Clipboard, and Focus features in the shallow overlay pattern from NotchHub
0.5-0.7. Its terminal-session, approval, and Claude status-line bridge is
unavailable because this build has no Developer ID identity or provisioned
shared Keychain group. Media, guided onboarding, and a Sparkle update feed are
not included in this preview. CodexBar is not integrated or bundled; no
CodexBar source, binary, or runtime is included.

Quit the stable NotchHub app while testing this preview. Both versions own the
same top-edge location and will overlap if they run together.
