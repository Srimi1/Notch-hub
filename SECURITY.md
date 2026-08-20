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
| `~/.cache/hermes-notify/state.db` | Coding-agent activity | Opened **read-only**; absent on most machines |

### Writes

| Destination | Contents |
| --- | --- |
| macOS Keychain (`com.notchhub.apikeys`) | Your AI provider API keys, one item per provider |
| `UserDefaults` | Module visibility, Next Up preferences, persistent timers, the Grok team ID, and the Anthropic probe toggle — **never** a key |
| EventKit | Marking a reminder complete, only when you tap Complete |
| `UNUserNotificationCenter` | A local notification when a timer you started finishes |
| `~/.cache/hermes-notify/approval_response.json` | Your allow/deny decision for an agent prompt |

## Network

NotchHub makes **no network request at all until you save an API key** in
Settings → AI Credits. Once a key is stored, the credit tracker polls the
matching provider every five minutes (and on a manual refresh):

| Host | Endpoint | Sent |
| --- | --- | --- |
| `management-api.x.ai` | `/auth/management-keys/validation`, `/v1/billing/teams/{id}/prepaid/balance` | Your xAI **management** key as a bearer token |
| `api.anthropic.com` | `/v1/organizations/cost_report` | Your Anthropic **admin** key as `x-api-key` |
| `api.anthropic.com` | `/v1/messages` | Your Anthropic key — **only** on a manual refresh, and only if you enable the rate-limit probe. This request is billable. |
| `api.openai.com` | `/v1/organization/costs` | Your OpenAI **admin** key as a bearer token |

Removing a key from Settings stops the corresponding requests. Google/Gemini has
no API-key balance endpoint, so its tile is a static placeholder and issues no
request.

Requests additionally open in your browser or Maps when *you* activate a Next Up
action (a meeting link, or an `https://maps.apple.com/` search for an event
location).

### Transport controls

- TLS 1.3 minimum, ephemeral session, no cookie storage, no URL cache.
- 15-second request and resource timeouts.
- **Cross-origin redirects are refused.** `URLSession` replays request headers
  across redirects, so a redirect off the original scheme/host/port would leak
  the API key; NotchHub rejects it and surfaces an error instead.
- Response bodies are **streamed and cut off at 2 MiB**, and a declared
  `Content-Length` above that is refused before any byte is read.
- Retries are limited to transient failures (429/5xx/timeout); auth and client
  errors are never retried.

There is **no certificate or public-key pinning**. NotchHub relies on the system
trust store, so an attacker able to install a trusted root on your Mac could
observe these requests. Pinning provider certificates is not currently
sustainable for a community project (rotation would break the app between
releases), so it is documented here rather than claimed.

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

## Elevated privilege (opt-in)

The RAM cleaner runs Apple's built-in `/usr/sbin/purge`. You may **optionally**
grant a passwordless `sudo` rule so it runs without a prompt. This is an explicit
choice you make; if you don't grant it, the app falls back to an authenticated
prompt. Review `Sources/NotchHub/Services/PurgePrivilege.swift` and
`MemoryCleanerService.swift` before enabling it.

## Sandboxing and distribution

NotchHub is **not App Sandboxed**. It needs Apple Events (media control), an
unsandboxed helper invocation (`purge`), and read access to a path outside a
container, none of which survive the sandbox in the current design.

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
