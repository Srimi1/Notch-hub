# Security Policy

## Supported versions

NotchHub is pre-1.0. Security fixes land on `main` and in the latest GitHub
release. Please reproduce an issue against one of those versions before
reporting it.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
vulnerability reporting instead:

[Report a vulnerability privately](https://github.com/Srimi1/Notch-hub/security/advisories/new)

Include the macOS version, NotchHub version or commit, reproduction steps, and
the expected impact. Reports will be acknowledged and, where appropriate,
coordinated privately through a fix and disclosure.

## Security posture

NotchHub has no backend, account system, telemetry, analytics, advertising, or
in-app HTTP client. Its runtime data comes from local macOS APIs and applications.

### Reads

| Source | Purpose | Permission behavior |
| --- | --- | --- |
| Calendar events | Upcoming events and Next Up actions | Full Calendar access is requested only after **Enable Calendar** |
| Reminders | Due reminders and completion actions | Full Reminders access is requested only after **Enable Reminders** |
| Apple Music or Spotify | Track metadata and transport state | A scan of a running player can trigger the macOS Automation prompt |
| Focus / Do Not Disturb | Best-effort state and an on-demand toggle | The toggle needs manually granted Accessibility; an existing Full Disk Access grant can improve the state read |
| Clipboard | In-memory text, image, and file history | Pasteboard reads require no prompt; protected-file metadata and thumbnails are skipped when Full Disk Access is unavailable |
| Battery and system counters | Battery, CPU, RAM, and disk sampling | No permission required |

Hiding Clipboard, Calendar, Reminders, or Media stops the corresponding polling
service. Calendar and Reminders never raise an access prompt from a background
refresh.

### Local changes

| Destination | Change |
| --- | --- |
| `UserDefaults` | Module visibility, Next Up settings, popup settings, timer records, and one-time migration flags |
| EventKit | Marks a reminder complete only after the user chooses that action |
| `UNUserNotificationCenter` | Schedules a local notification for a timer the user started |
| `SMAppService` | Registers or unregisters Launch at Login; registration is attempted once on first run and remains user-controlled afterward |
| Login Keychain | Deletes provider credentials left by the removed v0.1 credit tracker, once |

## Network behavior

NotchHub makes no direct runtime network requests. Building from source can
download Swift Package Manager tooling dependencies.

A user-selected Calendar action can hand a meeting URL to its registered app or
open an Apple Maps search. The receiving application may use the network.
NotchHub does not open either action without a user gesture.

Versions before 0.2 included a credit tracker for xAI, Anthropic, and OpenAI. The
tracker, its HTTP client, and its Keychain wrapper have been removed. On the first
current-version launch, `LegacyCredentialCleanup` deletes entries stored under
the Keychain service `com.notchhub.apikeys`.

## Untrusted input

Calendar and reminder text can be authored by other people. Before display,
NotchHub removes control characters, Unicode format and default-ignorable code
points, the Tags block, non-characters, and excessive combining-mark runs. The
result is also length-bounded.

Meeting links must have no embedded credentials and must use either an allowlisted
meeting scheme or HTTPS. HTTPS hosts are checked for valid syntax; known local and
special-use names, non-public literal IP ranges, and non-canonical numeric IP
spellings are rejected. NotchHub does not resolve a hostname before handing a
user-selected URL to macOS, so this is input validation rather than a claim about
the address returned by DNS.

Apple Maps URLs are constructed with `URLComponents` from sanitized,
length-bounded location text.

## Elevated privilege removed

The current app has no privileged code path and never asks for an administrator
password.

Versions up to 0.1 included a RAM cleaner that could install a sudoers rule at
`/etc/sudoers.d/notchhub` for `/usr/sbin/purge`. The cleaner and installer are
gone, but upgrading or deleting the app cannot remove a root-owned rule. If you
enabled it, remove it manually:

```bash
sudo rm -f /etc/sudoers.d/notchhub
```

Leaving that file in place preserves a passwordless root grant for
`/usr/sbin/purge`, even though current NotchHub code no longer uses it.

## Copy popup and paste detection

The copy popup can dismiss when the copied content is pasted. Global paste
detection requires Accessibility trust. NotchHub checks `AXIsProcessTrusted()`
without prompting and installs the monitor only when trust already exists.

The monitor exists only while a copy popup is visible, matches <kbd>⌘V</kbd>, and
is removed with the popup. Without Accessibility trust, the popup uses its normal
timeout. This behavior is covered by
`Tests/NotchHubTests/PasteEventMonitorTests.swift`.

## Code signing and privacy grants

macOS associates Calendar, Reminders, Automation, Accessibility, and related
privacy decisions with an app's code identity. Rebuilding with an ad-hoc signature
can therefore reset previous grants.

`scripts/build-app.sh` prefers `NOTCHHUB_SIGNING_IDENTITY`, then an available
Apple Development or Developer ID Application identity. Identity-signed builds
use the hardened runtime and
`Resources/NotchHub.entitlements`, whose only entitlement is
`com.apple.security.automation.apple-events`. If no identity is available, the
script creates an ad-hoc local build and reports that fallback.

## Sandboxing

NotchHub is not App Sandbox enabled. Its current integrations include EventKit,
Apple Events, Accessibility-driven Control Center interaction, the system
pasteboard, and optional reads of copied files. Any future sandboxing work must
preserve those user-visible behaviors without broadening data access.
