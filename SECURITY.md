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

NotchHub is a local-only macOS app. It has **no backend, no telemetry, and no
accounts** — nothing leaves your machine. To render its modules it reads:

- **Calendar** events (EventKit) — display only.
- **Now-playing media**, **clipboard**, **battery**, and **CPU/RAM/disk** stats.
- A **local SQLite file** of coding-agent notifications
  (`~/.cache/hermes-notify/state.db`), opened **read-only**.
- **Focus/DND** state via AppleScript.

It writes only:

- `~/.cache/hermes-notify/approval_response.json` — your allow/deny decision for
  an agent prompt.
- App preferences in `UserDefaults`.

### Elevated privilege (opt-in)

The RAM cleaner runs Apple's built-in `/usr/sbin/purge`. You may **optionally**
grant a passwordless `sudo` rule so it runs without a prompt. This is an explicit
choice you make; if you don't grant it, the app falls back to an authenticated
prompt. Review the relevant code in `Sources/NotchHub/Services/PurgePrivilege.swift`
and `MemoryCleanerService.swift` before enabling it.

### Distribution note

Release builds are **ad-hoc signed and not notarized**. macOS Gatekeeper will warn
on first launch. Prefer building from source (`./scripts/build-app.sh`) if you want
full provenance.

## Network

The only network call is an **optional** check for a local Ollama instance on
`http://localhost:11434`. No remote endpoints are contacted.
