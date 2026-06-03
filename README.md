# NotchHub

A macOS notch-overlay app (MacNotch alternative). The collapsed pill expands into a dashboard of 7 live modules—System, Battery, Media, Calendar, Clipboard, Focus/DND, RAM Cleaner—plus an AI Coding module tracking live Claude/Codex/Kimi agent status. Built as a Swift Package, runs as a lightweight menu-bar agent.

## Build & Run

Requires macOS + the Swift toolchain (Xcode or Command Line Tools).

```bash
# Build the release .app (ad-hoc signed) and launch it
./scripts/build-app.sh
open NotchHub.app

# Or install to /Applications, then launch from Spotlight
cp -R NotchHub.app /Applications/
```

To start on login: click the `◖◗` menu-bar icon → **Launch at Login**.

### Development

```bash
swift build          # debug build
swift test           # run the test suite
./scripts/check.sh   # full quality gate: build, tests, format, lint, concurrency
```

> First launch: ad-hoc signing means Gatekeeper warns once — right-click the app → **Open** to whitelist it.
