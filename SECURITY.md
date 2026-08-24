# Security Policy

## Supported versions

NotchHub is pre-1.0 and ships from `main`. Security fixes land on `main`; please
test against the latest commit before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository
(<https://github.com/Srimi1/Notch-hub/security/advisories/new>).

Include the macOS version, NotchHub commit, reproduction steps, and impact.
You'll get an acknowledgement and, where applicable, a coordinated fix and credit.

## What NotchHub accesses (transparency)

NotchHub has **no backend, no telemetry, and no accounts**. It does, however,
talk directly to third-party AI provider APIs when *you* configure a key — see
[Network](#network). Everything else stays on your machine.

### Reads

| Source | Purpose | Permission |
| --- | --- | --- |
| Calendar events (EventKit) | Upcoming-event display | `NSCalendarsFullAccessUsageDescription` prompt |
| Reminders (EventKit) | Due-reminder display and completion | `NSRemindersFullAccessUsageDescription` prompt |
| Now-playing media | Media module and controls | Apple Events prompt |
| Focus / Do Not Disturb state | Focus activity | AppleScript |
| Clipboard | Clipboard history module | None (macOS grants pasteboard read) |
| Battery, CPU, RAM, disk | System module | None |

### Writes

| Destination | Contents |
| --- | --- |
| `UserDefaults` | Module visibility, Next Up preferences, popup switches, and persistent timers |
| EventKit | Marking a reminder complete, only when you tap Complete |
| `UNUserNotificationCenter` | A local notification when a timer you started finishes |

## Network

NotchHub makes **no network requests.** There is no networking code in the app.

Earlier versions shipped a credit tracker that polled xAI, Anthropic, and OpenAI
with API keys from your Keychain. It has been removed, along with the HTTP client
and the Keychain wrapper it used. The first launch after upgrading deletes the
keys it stored (service `com.notchhub.apikeys`); you can confirm with
`security find-generic-password -s com.notchhub.apikeys`.

The only outbound traffic NotchHub can still cause is indirect: opening a meeting
link or an Apple Maps search **in your browser**, and only when you activate a
Next Up action yourself. Those URLs are validated first — see below.

## Untrusted input

Calendar and reminder text comes from other applications and is rendered in an
always-on-top overlay, so it is sanitized before display: control and Unicode
format characters (including the bidi overrides and isolates), all
default-ignorable code points, the Tags block, non-characters, and runaway
combining-mark stacks are stripped, and text is length-bounded.

Meeting links are only opened when they are `https` with a **public** host, or
one of a small set of meeting schemes. Loopback, private, link-local,
carrier-grade-NAT, unique-local, multicast, and special-use names and addresses
are refused, as are octal/hex/dword spellings of an IP address.

## Elevated privilege: removed

NotchHub contains **no privileged code path** and never asks for an administrator
password.

Versions up to v0.1.x included a RAM cleaner that ran `/usr/sbin/purge` as root,
either through an authentication dialog or — if you opted in — through a sudoers
rule at `/etc/sudoers.d/notchhub` granting passwordless `sudo` for that one
binary. The cleaner and the rule-installer are both gone.

**Removing the app does not remove that rule**, and neither does upgrading:
deleting a root-owned file requires an administrator password, and a release
whose purpose is removing the privileged path should not prompt you for one. If
you enabled it, remove it yourself:

```bash
sudo --non-interactive --list /usr/sbin/purge   # prints the path if still installed
sudo rm -f /etc/sudoers.d/notchhub
```

The residual risk if you leave it is narrow — the rule grants exactly
`/usr/sbin/purge`, with no argument wildcard — but it is still a standing
passwordless root grant, so remove it.

## The copy popup and the ⌘V monitor

The copy popup can dismiss the moment its content is pasted. Detecting ⌘V
anywhere on the system uses a global key monitor, which macOS only feeds to
apps trusted for Accessibility. NotchHub **never requests** that permission for
this: it checks `AXIsProcessTrusted()` — the non-prompting read — and when the
grant is absent (it is, unless you granted it for the Focus toggle) the monitor
is simply never installed and the popup falls back to its timer.

When the monitor does run: it exists only while a copy popup is on screen, it
is torn down with it, and the handler matches ⌘V and does nothing else with the
event. The gating is enforced by unit tests
(`Tests/NotchHubTests/PasteEventMonitorTests.swift`), not by convention.

## Code signing and privacy grants

macOS ties privacy grants (Calendar, Reminders, Apple Events) to an app's code
signature. An **ad-hoc** signature is regenerated on every build, so each rebuild
looks like a different application and the grants are discarded — the symptom is
an app that seems to ask for the same permission forever.

`scripts/build-app.sh` therefore prefers a real identity: `Apple Development` or
`Developer ID Application` from your keychain, or whatever you set in
`NOTCHHUB_SIGNING_IDENTITY`. Identity-signed builds use the hardened runtime and
carry a single entitlement, `com.apple.security.automation.apple-events`, which
is required for media transport and the Focus toggle to drive other apps.

With no certificate available the build still works, ad-hoc, and says so.

## Sandboxing and distribution

NotchHub is **not App Sandboxed**. It needs Apple Events for media and Focus
control, plus EventKit. The two other blockers — the unsandboxed `purge`
invocation and a read of `~/.cache/hermes-notify` outside any container — were
removed with the RAM cleaner and the coding monitor, so sandboxing is now a
realistic option rather than a design conflict. It is not done yet.

**NotchHub ships as source. No pre-built binary is distributed.**

A binary built without an Apple Developer Program identity can only be **ad-hoc
signed**, and macOS Gatekeeper refuses ad-hoc-signed apps that arrive by
download. Publishing one would mean asking every user to override Gatekeeper for
a binary they cannot independently verify, so we don't publish one. Build from
source with `./scripts/build-app.sh` — an app you compile yourself is never
quarantined, and you get full provenance.

`scripts/build-app.sh` and `scripts/build-dmg.sh` already implement the
Developer ID + hardened runtime + notarization flow via
`NOTCHHUB_SIGNING_IDENTITY` and `NOTCHHUB_NOTARY_PROFILE`, including stapling
and a Gatekeeper assessment. A signed, notarized binary release will be
published once an Apple Developer Program identity is available for this
project.
