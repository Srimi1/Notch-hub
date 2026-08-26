# Changelog

Notable user-facing changes are recorded here. NotchHub follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while the public API
and interface continue to mature before 1.0.

## [Unreleased]

### Added

- The clipboard picker can be opened by tapping N twice. The gesture only fires
  after a pause in typing and with nothing between the two taps, so words like
  "announce" cannot set it off; it needs Accessibility, and it does not take the
  key away from the app underneath, so both letters are still typed. There is a
  toggle for it in Settings.

### Fixed

- Fixed clicking a peek card typing its ⌘V into the notch itself. The click
  makes the panel the key window without borrowing focus from anywhere, so
  there is nowhere to hand the keyboard back to; the card now copies and says
  so, like the dashboard's clipboard tiles.
- Fixed the collapsed notch appearing as an oversized empty black slab. The
  subscription that resizes the pill read the "show wings" flag back off the
  view model instead of using the value it was handed, and that property
  publishes before it is updated — so the window was sized for the previous
  state. It stayed narrow as an activity arrived, and widened as one left,
  leaving a pill twice the width of the notch with nothing drawn in it.
- Fixed a crash-looping media adapter relaunching every second for the rest of
  the session, which is what kept the pill growing and shrinking on its own. A
  run now counts as healthy only if it lasted, rather than if it printed
  anything before dying.
- Fixed the clipboard picker opening clipped off the top of the screen when the
  dashboard was already open. Two window animations were started against each
  other, and the frame could settle on the smaller one while the content was
  already picker-sized.
- Fixed the picker's first row rendering behind the camera housing.
- Fixed the dashboard being 2 points too short for its own contents on the 14"
  and 16" MacBook Pros, where the notch is taller.
- Fixed the test suite writing its fixtures to the clipboard the user was
  actually using: running the suite while NotchHub was running put strings like
  "first" and "alpha" into the history, and from there into documents.
- Fixed copies being lost when NotchHub sampled the pasteboard mid-write. The
  change counter is bumped before the new content exists, and that generation
  was being marked as seen regardless — so the copy never entered the history
  and the next paste from the notch gave back the one before it.
- Fixed concealed content being recorded when its privacy marker had not yet
  landed. The markers are now checked on both sides of the read.
- Fixed ⌘1 through ⌘9 selecting and pasting a clip while the picker was open.
  They belong to the app underneath — switching browser tabs, most often — and
  were being swallowed as well as acted on.
- Fixed Return and Space silently pasting the newest clip when Full Keyboard
  Access is on. They now close the picker.
- Fixed a paste going out after something else had taken the pasteboard in the
  moment between the copy and the keystroke.
- Fixed held modifiers reaching the synthesized ⌘V: with the ⌃⌥V shortcut still
  under the user's fingers, Finder saw ⌘⌃⌥V, which is Move Item Here.
- Fixed holding the shortcut down toggling the picker open and shut repeatedly.
- Fixed a multi-file copy landing in reverse order and raising one popup per
  file rather than one for the gesture.
- Fixed the dashboard's clipboard tiles trying to paste into the notch itself.
  They copy, and say so.
- Fixed the notch flickering open and shut under a stationary pointer, which
  left it unusable while it lasted. Resizing the overlay rebuilds its tracking
  area, and AppKit reports the pointer as having left even though it has not
  moved; the collapse that caused was undone the moment it finished, and the
  cycle repeated. Enter and exit are now ignored while the frame is moving, and
  the hover state is reconciled from the pointer's real position once it stops.

## [0.3.3] - 2026-08-26

### Fixed

- Fixed NotchHub starting two media adapter processes instead of one. Reaping
  strays from an earlier run waits on `pkill`, and waiting spins the run loop,
  so work already queued on the main actor ran inside that wait and reached
  `start()` again before the first launch had recorded itself. Both processes
  then streamed the same data for the life of the session.
- Fixed output being dropped when an adapter process wrote and exited
  immediately. The termination handler tore down the pipe before the read
  handler had run, discarding whatever the process had said on its way out —
  which is the case where its output matters most.

## [0.3.2] - 2026-08-25

### Changed

- Now-playing from system playback starts with the app instead of waiting for
  your first hover. The collapsed notch could not show a track until you had
  opened the dashboard once per launch, which is most of the point of a notch
  overlay. The reader that made this possible asks macOS for nothing, so there
  was no reason to gate it.
- The Music and Spotify half still waits for that first interaction. Its opening
  query is what raises the macOS Automation prompt, and a new user should not
  meet that before they have seen the app. Hiding the Media module continues to
  stop both halves outright.

## [0.3.1] - 2026-08-25

A packaging release. The app is unchanged; how it is built and shipped is not.

### Fixed

- Fixed the published app being Apple Silicon only. Release builds are now
  universal (`arm64` + `x86_64`), so NotchHub runs on Intel Macs. SwiftPM cannot
  build both slices in one pass in this package, so `scripts/build-app.sh` builds
  each and joins them with `lipo`.
- Fixed a SwiftPM warning about an unhandled file by excluding the stray
  `ruvector.db` from the target again.

## [0.3.0] - 2026-08-25

### Added

- Added now-playing support for every player, not just Apple Music and Spotify.
  A bundled copy of [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  reads the system's own now-playing state, so a YouTube Music tab, a web app, or
  an Electron client appears in the notch with working transport controls.
  Transport is routed back to whichever source produced the track.
- Added a global clipboard shortcut. `⌘⇧Space` from any app drops the clip
  history out of the notch; digits `1`–`9` pick and `Esc` closes. `⌃⌥V` and
  `⌘⇧V` are offered in Settings; `⌘Space` is not, because Spotlight owns it.
- Added automatic pasting. Picking a clip types the `⌘V` into whatever you were
  working in when Accessibility is granted, and says so once when it is not.
- Added a permissions walkthrough on first launch and a Permissions section in
  Settings, covering Accessibility, Automation, Calendar, Reminders,
  Notifications, and Full Disk Access — what each one buys, its current state,
  and the control that moves it forward.
- Added `scripts/build-adapter.sh`, which builds the adapter framework with
  plain `clang` and no CMake dependency.

### Fixed

- Fixed picking a clip pasting the wrong one. Restoring a clip re-ordered the
  history under the cursor, so the next click landed on a different tile.
- Fixed Do Not Disturb reporting the opposite of the truth. The state was never
  actually read, so on a Mac where it was already on the button offered "Turn
  On", turned it off, and then showed a "Focus is on" pill for the rest of the
  session. The state is now read back from Control Center after a toggle, and
  shown as unknown rather than guessed when nothing can read it.
- Fixed the Focus toggle blaming the wrong permission. A denied Apple Event was
  reported as a missing Accessibility grant, sending people to a list where
  NotchHub was already ticked.
- Fixed Calendar, Reminders, and Notifications opening the Accessibility pane,
  which has no switch for any of them.
- Fixed Full Disk Access never being satisfiable on a Mac that had never used a
  Focus mode, where the only probe file did not exist.
- Fixed the clipboard picker being invisible while the dashboard was open, then
  dropping out of the notch unasked a moment later.
- Fixed the picker keeping the keyboard after it closed, which sent the
  synthesized `⌘V` to the notch instead of the document and stranded later
  keystrokes.
- Fixed the picker sticking on screen as a click-blocking overlay after it lost
  the keyboard.
- Fixed copy and charging popups replacing the picker mid-selection.
- Fixed clipboard thumbnails leaking when entries were replaced or trimmed.
- Fixed peek-card clicks expanding the dashboard instead of picking, and tile
  padding not being clickable.
- Fixed hiding the Media module leaving the last track pinned in the notch for
  the rest of the session.
- Fixed the media adapter surviving quit when its `SIGTERM` was swallowed, and
  added cleanup for a process orphaned by a force-quit.
- Fixed `scripts/build-dmg.sh` refusing to package the app once it contained a
  framework, because it rejected every symlink.

### Changed

- Changed `NowPlaying.app` from a two-case enum to a display name plus bundle
  identifier. Browser playback is labelled with the app macOS reports, so a
  YouTube Music tab in Safari reads as "Safari" while the installed web app
  reads as "YouTube Music".
- Changed an inconclusive Full Disk Access check to read as unavailable, so
  optional protected-file reads are skipped rather than risking a folder prompt.
  The probe no longer depends on the user having used a Focus mode.
- Moved the media stack to `Sources/NotchHub/Services/Media/`, split into a
  coordinator over two interchangeable sources.

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

[Unreleased]: https://github.com/Srimi1/Notch-hub/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/Srimi1/Notch-hub/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/Srimi1/Notch-hub/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Srimi1/Notch-hub/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Srimi1/Notch-hub/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Srimi1/Notch-hub/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Srimi1/Notch-hub/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Srimi1/Notch-hub/releases/tag/v0.1.0
