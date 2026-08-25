# Changelog

Notable user-facing changes are recorded here. NotchHub follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while the public API
and interface continue to mature before 1.0.

## [Unreleased]

### Changed

- Removed the Full Disk Access prompt from Settings. NotchHub now treats an
  inconclusive access check as unavailable and skips optional protected-file
  reads without asking for a broad permission.

## [0.2.1] - 2026-08-25

### Added

- Added the final black-and-white NotchHub identity across the app and repository.
- Added protected-folder handling so optional file reads can be skipped when
  Full Disk Access is unavailable.
- Added focused permission tests for copied files.

### Fixed

- Prevented copied files from triggering an unsolicited folder-access prompt
  while NotchHub prepares thumbnail and file-size details.
- Kept the Clipboard dashboard collapsible after it is opened from the copy popup.

### Documentation

- Rebuilt the README around direct product screenshots, exact permission behavior,
  supported modules, service lifecycles, and current limits.

## [0.2.0] - 2026-08-25

### Added

- Added a ranked Next Up queue for calendar events, reminders, timers, battery,
  media playback, and Focus state.
- Added copy, clipboard-preview, and charging HUDs that grow from the notch.
- Added persistent timers, local completion notifications, live battery drawing,
  stable module preferences, and a flat native Settings window.
- Added explicit Calendar and Reminders access controls, stable code-signing
  support, a single-instance guard, and notchless-display fallback geometry.

### Changed

- Reduced the dashboard to seven working modules: Dashboard, Media, Calendar,
  Todo, Pomodoro, Clipboard, and Focus.
- Moved module visibility and activity preferences into Settings.
- Deferred permission-sensitive services until the relevant module or user action
  needs them.

### Removed

- Removed the RAM cleaner and its privileged helper path.
- Removed the AI coding monitor, credit tracker, network client, and stored API keys.
- Added a one-time cleanup for credentials left by version 0.1.

## [0.1.0] - 2026-08-20

- Published the first public NotchHub release.

[Unreleased]: https://github.com/Srimi1/Notch-hub/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/Srimi1/Notch-hub/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Srimi1/Notch-hub/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Srimi1/Notch-hub/releases/tag/v0.1.0
