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
`NotchHubLite`, and `NotchHubHookBridge` is the bounded command-hook relay.

Build runnable app bundles with:

```sh
./scripts/build-app.sh direct debug
./scripts/build-app.sh lite debug
```

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
