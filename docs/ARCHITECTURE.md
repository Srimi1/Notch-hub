# NotchHub architecture

NotchHub is a single-process macOS 14 accessory app built as a Swift Package
executable. AppKit owns the process lifecycle, menu-bar item, overlay panel, and
display geometry. SwiftUI renders the overlay and Settings. A shared `ServiceHub`
supplies local state to both interfaces.

## Source map

| Area | Primary files |
| --- | --- |
| Process lifecycle | [`main.swift`](../Sources/NotchHub/main.swift), [`AppDelegate.swift`](../Sources/NotchHub/AppDelegate.swift) |
| Overlay window | [`NotchWindowController.swift`](../Sources/NotchHub/Core/NotchWindowController.swift), [`NotchPanel.swift`](../Sources/NotchHub/Core/NotchPanel.swift), [`NotchGeometry.swift`](../Sources/NotchHub/Core/NotchGeometry.swift) |
| Presentation state | [`NotchViewModel.swift`](../Sources/NotchHub/Core/NotchViewModel.swift), [`NotchViewModel+HUD.swift`](../Sources/NotchHub/Core/NotchViewModel+HUD.swift) |
| Service composition | [`ServiceHub.swift`](../Sources/NotchHub/Services/ServiceHub.swift) and `Sources/NotchHub/Services/*` |
| Activity ranking | [`ActivitySnapshotFactory.swift`](../Sources/NotchHub/Core/ActivitySnapshotFactory.swift), [`ActivityCoordinator.swift`](../Sources/NotchHub/Core/ActivityCoordinator.swift) |
| Dashboard and Settings | [`ExpandedDashboardView.swift`](../Sources/NotchHub/UI/ExpandedDashboardView.swift), [`SettingsRootView.swift`](../Sources/NotchHub/UI/SettingsRootView.swift) |
| External-input checks | [`UntrustedInput.swift`](../Sources/NotchHub/Core/UntrustedInput.swift), [`EventKitAccess.swift`](../Sources/NotchHub/Core/EventKitAccess.swift) |

## Runtime ownership

| Owner | Responsibility |
| --- | --- |
| `main.swift` | Creates `NSApplication`, selects accessory activation, installs `AppDelegate`, and enters the AppKit run loop. |
| `AppDelegate` | Owns the single-instance guard, shared module preferences, `ServiceHub`, launch-at-login controller, status item, overlay controller, and Settings window. |
| `ServiceHub` | Constructs each service once, forwards observable changes, applies module-visibility lifecycle rules, and refreshes activity candidates. |
| `NotchWindowController` | Chooses display geometry, owns the panel, hosts SwiftUI, and animates between collapsed, HUD, and expanded frames. |
| `NotchViewModel` | Owns interaction state, selected module, activity presentation, HUD timing, and action routing. It receives the shared preferences and service hub. |
| `ModulePreferences` | Persists visible modules and the last active module, validating stored enum identifiers on load. |

`LSUIElement` is enabled in `Resources/Info.plist`, so NotchHub has no normal Dock
presence. `NotchPanel` is a non-activating panel at status-bar level. It joins all
Spaces, can accompany full-screen windows, and yields behind peer overlays while
collapsed.

## Startup

1. `AppDelegate` runs the single-instance check. A losing duplicate exits before
   creating UI.
2. The delegate performs one-time legacy credential cleanup and the first-run
   Launch at Login attempt.
3. `ServiceHub.startAmbient()` starts the non-interactive service set.
4. The delegate creates the status menu with **Toggle Notch**, **Settings**, and
   **Quit NotchHub**.
5. If a display is available, `NotchWindowController` creates a `NotchViewModel`
   with the existing preferences and service hub, then shows the collapsed panel.
6. The first hover expansion or menu toggle calls `ServiceHub.startInteractive()`
   once. Media and Calendar then start only if their modules are visible.

A Launch at Login process can start before a display wakes. In that case the app
keeps its services and status item alive, then installs the overlay after macOS
reports a display change.

## Display and presentation

`NSScreen.notchScreen` chooses the first display with a physical notch. If none
exists, it uses the main screen and then the first available screen. There is no
active-display follower or screen picker.

| Tier | Size and role |
| --- | --- |
| Collapsed | Matches the physical camera area. Notchless displays use a chip 190 points wide and at least 32 points tall. Non-ambient activity can add symmetric wings. |
| HUD | A 520 × 104 point temporary surface for copy feedback, clipboard preview, or a charging event. |
| Picker | A 560 × 360 point clipboard history, opened by the global chord or by tapping N twice. It borrows key status so it can read digit keys, and hands it back on the way out. |
| Expanded | An 860 point dashboard, 136 points tall or as tall as the notch requires, with width clamped to the display width minus 40 points. |

Both properties behind the tier map are separately published and `isExpanded`
outranks `hudContent`, so a presentation that changes both has to set them in
the order that keeps the intermediate state on a tier already showing.
Otherwise the window animates towards one size while the content is laid out
for another, and since the panel hangs from the top of the screen the excess
runs off the display rather than overhanging below it.

Hover expands the interface and pointer exit schedules collapse after 0.15
seconds. **Toggle Notch** pins the expanded tier until toggled again. A clipboard
preview promotes after 0.6 seconds; Reduce Motion skips that intermediate reveal.

## Service lifecycle

`ServiceHub` starts services according to both interaction phase and module
visibility. Hiding Clipboard, Todo, Calendar, or Media stops the corresponding
service instead of merely hiding its view.

| Service | Starts | Cadence and source | Stops when hidden |
| --- | --- | --- | --- |
| Time | App launch | Every second from the system clock | No |
| System monitor | App launch | Every 2 seconds from Mach/BSD and volume-capacity APIs | No |
| Battery | App launch | Every 30 seconds plus IOKit power-source changes | No |
| Timers | App launch | Every second | No |
| Focus | App launch | Best-effort initial read; toggle runs only on user action | No |
| Clipboard | App launch when Clipboard is visible | Pasteboard `changeCount` every 0.25 seconds | Yes |
| Reminders | App launch when Todo is visible | Authorization check and EventKit refresh every 60 seconds | Yes |
| Calendar | First interaction when Calendar is visible | EventKit every 60 seconds plus store-change notifications | Yes |
| Media | First interaction when Media is visible | AppleScript query of running Music or Spotify every 2 seconds | Yes |

Calendar and Reminder refreshes re-read authorization without prompting. Their
access requests are separate operations invoked only from explicit **Enable**
actions. A first interactive Media query can trigger an Automation prompt when a
supported player is running.

## Feature modules

Modules are compile-time routes, not plugins. `FeatureModule` has seven cases and
`ExpandedDashboardView` switches over them exhaustively.

| Module | View and service path |
| --- | --- |
| Dashboard | `DashboardModuleView` with time, battery, CPU, and memory state |
| Media | `MediaModuleView` with `MediaService` |
| Calendar | `CalendarModuleView` with `CalendarService` |
| Todo | `ReminderModuleView` with `ReminderService` |
| Pomodoro | `TimerModuleView` with `ActivityTimerService` |
| Clipboard | `ClipboardModuleView` with `ClipboardService` |
| Focus | `FocusModuleView` with `FocusService` |

Visibility is configured in Settings. The dashboard shows visible modules in
canonical enum order. Module chips and <kbd>⌘1</kbd> through <kbd>⌘9</kbd> select a
visible route while the panel is interactive. The last selection is persisted and
validated at the next launch. A stored empty module list is respected.

## Activity pipeline

`ServiceHub.refreshActivities()` converts current Calendar, Reminder, Timer,
Battery, Media, and Focus state through `ActivitySnapshotFactory`. The factory
assigns a kind, priority, relevance date, stable identifier, and at most two
actions to each candidate.

`ActivityCoordinator` then:

1. removes activity kinds disabled in `ActivityPreferences`;
2. ranks the remainder by effective priority, relevance date, and stable ID;
3. lets a higher-priority candidate preempt immediately;
4. preserves the current item for four seconds before an equal or lower-priority
   switch; and
5. publishes the current item plus up to four queued items.

Ambient activity stays out of the collapsed wings and automatic detail view.
Activity actions are routed through `NotchViewModel` to the relevant local service
or a validated external Calendar action.

## State and persistence

| Store | Data | Lifetime and bounds |
| --- | --- | --- |
| `UserDefaults` | Module layout, activity settings, popup settings, timer JSON, migration flags | Persists across launches; identifiers and numeric preferences are validated; timer records are capped at eight |
| Process memory | Clipboard text, raw images, file URLs, and thumbnails | Capped at 12 entries and cleared on quit; up to four files are accepted from one copy event |
| EventKit | Upcoming events and incomplete reminders | Owned by macOS; NotchHub reads after an explicit grant and writes only reminder completion requested by the user |
| Login Keychain | Legacy provider keys only | Current code stores no secrets and performs a one-time deletion of keys written by the removed v0.1 credit tracker |

`ServiceHub` forwards Combine publishers from its observable child services.
Observation-based Timer and Reminder services use explicit change callbacks. Any
relevant service or preference change rebuilds and re-ranks the activity set.

## Permission and input boundaries

`EventKitAccessDecision` gives Calendar and Reminders one testable mapping from
macOS authorization status to granted, denied, or needs-prompt. Both services
re-check status on their refresh tick and when the app becomes active. Granting or
revoking access in System Settings therefore updates the running app without a
relaunch.

`DisplaySanitizer` handles Calendar titles, Calendar locations, Reminder titles,
and timer labels. It removes characters that can hide or reorder overlay text,
bounds combining marks, and limits output length. Clipboard and Media content use
separate display paths and are not part of this sanitizer boundary.

`SafeExternalURL` validates user-selected Calendar actions before
`NSWorkspace.open`:

- meeting links reject embedded credentials and non-allowlisted schemes;
- HTTPS links reject malformed hosts, known local or special-use names,
  non-public literal IP ranges, and non-canonical numeric address spellings;
- hostname validation is syntactic and does not perform DNS resolution; and
- Apple Maps URLs are constructed with `URLComponents` from sanitized,
  length-bounded location text.

Clipboard history stays in memory. Concealed, transient, and autogenerated
pasteboard items are ignored. Without Full Disk Access, NotchHub avoids metadata
and Quick Look reads for file URLs inside Desktop, Documents, Downloads, and
iCloud Drive.

Focus toggles Do Not Disturb through Accessibility-driven Control Center scripting.
Its state begins with a best-effort read of the protected Do Not Disturb assertions
file, so it can be stale when Full Disk Access is unavailable or another app
changes Focus later.

See [`SECURITY.md`](../SECURITY.md) for the complete access and reporting policy.

## Build and verification

`Package.swift` defines one macOS 14 executable target and one test target. The
manifest uses Swift tools 5.9 while strict-concurrency migration remains in
progress. SwiftFormat and SwiftLint are development dependencies; the executable
has no third-party runtime package.

```bash
swift build
swift test
./scripts/check.sh
./scripts/build-app.sh release
```

The full check builds the app and tests, verifies SwiftFormat, and reports strict
concurrency diagnostics. With full Xcode selected, it also runs SwiftLint and the
test suite. GitHub Actions runs build, test compilation, formatting, linting, and
tests for pushes and pull requests targeting `main`.

## Change checklist

| Change | Required touch points |
| --- | --- |
| Add a module | Extend `FeatureModule`, add a concrete SwiftUI view and exhaustive dispatch case, decide default visibility, and test preference restoration. |
| Add a service | Define isolation and lifecycle, construct it in `ServiceHub`, forward changes, stop owned work, and surface typed errors. |
| Add an activity source | Extend `ActivityKind`, create bounded snapshots, wire refresh and action routing, expose preferences, and add ranking tests. |
| Accept external text or URLs | Define the exact trust boundary, reuse or extend the central validation types, and add hostile-input tests. |
| Add a permission | Keep prompting behind an explicit user action where macOS permits it, provide recovery guidance, and update `SECURITY.md`. |
