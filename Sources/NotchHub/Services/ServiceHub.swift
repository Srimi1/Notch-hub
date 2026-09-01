import AppKit
import Combine
import Foundation
import SwiftUI

/// Holds a `NotificationCenter` observer token and unregisters it when the token
/// itself is released. Owning the token in a plain (non-isolated) box lets an
/// actor-isolated type clean up without touching its own state from `deinit`.
///
/// The value is only ever written from its owner's isolation domain, which is
/// what makes the unchecked conformance sound.
final class NotificationObserverToken: @unchecked Sendable {
    var value: (any NSObjectProtocol)?

    var isEmpty: Bool { value == nil }

    deinit {
        if let value {
            NotificationCenter.default.removeObserver(value)
        }
    }
}

/// Single owner of every live data service. Injected into the SwiftUI
/// environment so any module view can read live state, and given a coarse
/// lifecycle so polling only runs while the app is active.
///
/// This is the service layer NotchHub previously lacked — the reason every
/// module rendered hardcoded placeholder data. Mirrors how MacNotch fans a set
/// of `ObservableObject` singletons (`MediaService`, `BluetoothService`,
/// `SystemMonitorService`, …) out to its `*ModuleView`s.
@MainActor
final class ServiceHub: ObservableObject {

    let time = TimeService()
    let system = SystemMonitorService()
    let battery = BatteryService()
    let media = MediaService()
    let calendar = CalendarService()
    let clipboard = ClipboardService()
    let focus = FocusService()
    let reminders = ReminderService()
    let timers = ActivityTimerService()
    let activityPreferences = ActivityPreferences()
    let hudPreferences = HudPreferences()
    let screenshotPreferences = ScreenshotPreferences()
    let screenshots: ScreenshotService
    let activityCoordinator: ActivityCoordinator

    private var started = false
    private var startedInteractive = false
    private var cancellables = Set<AnyCancellable>()
    /// Coalescing flag for activity rebuilds — see `setNeedsActivityRefresh`.
    private var activityRefreshScheduled = false
    /// A slow timer so time-relative activity windows (a meeting entering its
    /// lead time, a reminder coming due) still advance without a data change
    /// driving them — see `startAmbient`.
    private var activityTimer: Timer?
    /// Owns the activation observer so it is unregistered when the hub goes
    /// away. Deregistering from `ServiceHub.deinit` directly would mean touching
    /// main-actor state from a nonisolated deinit, which is an error under
    /// Swift 6; a plain box has no such isolation to violate.
    private let activationObserver = NotificationObserverToken()

    /// Dashboard layout preferences, used here as a *lifecycle* gate rather
    /// than a display one. `nil` means "run everything", for tests and previews.
    private let modulePreferences: ModulePreferences?

    init(modulePreferences: ModulePreferences? = nil) {
        self.modulePreferences = modulePreferences
        activityCoordinator = ActivityCoordinator(preferences: activityPreferences)
        screenshots = ScreenshotService(preferences: screenshotPreferences)

        // Re-publish whenever any child service changes, so container views
        // that switch on cross-service state (the live strip, the collapsed
        // wing selector) stay reactive without observing each child directly.
        //
        // Only the services whose data actually feeds an activity snapshot also
        // request an activity rebuild — see `ActivityRelevance`. The clock, the
        // system monitor and the clipboard do not, and letting the 1s clock
        // rebuild and re-rank every activity on each tick was needless
        // main-thread churn that showed up as a stutter as the notch opened.
        let labelledPublishers: [(String, ObservableObjectPublisher)] = [
            ("time", time.objectWillChange),
            ("system", system.objectWillChange),
            ("battery", battery.objectWillChange),
            ("media", media.objectWillChange),
            ("calendar", calendar.objectWillChange),
            ("clipboard", clipboard.objectWillChange),
            ("focus", focus.objectWillChange)
        ]
        for (label, publisher) in labelledPublishers {
            let drivesActivities = ActivityRelevance.drivesActivities(label)
            publisher
                .sink { [weak self] in
                    self?.objectWillChange.send()
                    if drivesActivities {
                        Task { @MainActor [weak self] in self?.setNeedsActivityRefresh() }
                    }
                }
                .store(in: &cancellables)
        }

        screenshots.onCapture = { [weak self] capture in self?.copyScreenshot(capture) }
        screenshots.onChange = { [weak self] in self?.objectWillChange.send() }
        screenshotPreferences.onChange = { [weak self] in self?.applyScreenshotWatching() }

        timers.onChange = { [weak self] in self?.setNeedsActivityRefresh() }
        reminders.onChange = { [weak self] in self?.setNeedsActivityRefresh() }
        activityPreferences.onChange = { [weak self] in
            self?.activityCoordinator.refreshForPreferences()
            self?.setNeedsActivityRefresh()
        }

        modulePreferences?.$visibleModules
            .removeDuplicates()
            .sink { [weak self] modules in
                Task { @MainActor [weak self] in
                    self?.applyModuleVisibility(Set(modules))
                }
            }
            .store(in: &cancellables)
    }

    /// Starts or stops gated services to match the visible-module set.
    ///
    /// The gated ones are those that read something a user may not want read:
    /// pasteboard contents, Apple Events to the media players, and calendar and
    /// reminder contents.
    ///
    /// Hiding a module used to only hide its tab: unchecking Clipboard still
    /// read the pasteboard every second, and unchecking Media still sent Apple
    /// Events to Music and Spotify for the whole session. A privacy-relevant
    /// switch has to actually switch something off.
    private func applyModuleVisibility(_ visible: Set<FeatureModule>) {
        guard started else { return }

        setRunning(clipboard.start, clipboard.stop, visible.contains(.clipboard))
        setRunning(reminders.start, reminders.stop, visible.contains(.todo))

        // System-wide playback prompts for nothing, so it follows the module's
        // visibility directly. The Apple Events half does prompt, so it still
        // waits for the first expand — as does Calendar.
        if visible.contains(.media) {
            media.startSystemPlayback()
            if startedInteractive { media.startScriptedPlayers() }
        } else {
            media.stop()
        }
        if startedInteractive {
            setRunning(calendar.start, calendar.stop, visible.contains(.calendar))
        }
        setNeedsActivityRefresh()
    }

    /// Whether a change from a given service should trigger an activity rebuild.
    ///
    /// Activity snapshots are built from calendar, reminders, timers, battery,
    /// media and focus. The clock, the system monitor and the clipboard never
    /// change activity content, so a change from them must not rebuild and
    /// re-rank the whole activity set — the 1s clock doing exactly that, forever,
    /// was pure churn and part of why opening the notch stuttered.
    enum ActivityRelevance {
        static let excluded: Set<String> = ["time", "system", "clipboard"]

        static func drivesActivities(_ service: String) -> Bool {
            !excluded.contains(service)
        }
    }

    /// Collapse a burst of service changes into a single activity rebuild on the
    /// next main-actor turn, instead of rebuilding once per publisher per tick.
    func setNeedsActivityRefresh() {
        guard !activityRefreshScheduled else { return }
        activityRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityRefreshScheduled = false
            self.refreshActivities()
        }
    }

    /// A screenshot NotchHub noticed, on its way to the pasteboard.
    ///
    /// Always copied — that is the feature the user switched on. Kept in the
    /// history and announced with the popup only while the Clipboard module is
    /// visible, because hiding that module is the user asking NotchHub not to
    /// keep or show their clipboard.
    private func copyScreenshot(_ capture: CapturedScreenshot) {
        let remember = ScreenshotService.shouldRemember(
            clipboardModuleVisible: isVisible(.clipboard)
        )
        clipboard.offer(.image(capture.pngData), remember: remember)
    }

    /// The watcher follows its own switch in Settings, not a module's
    /// visibility — there is no Screenshots module, and the folder grant is
    /// too consequential to be turned on by a dashboard layout change.
    private func applyScreenshotWatching() {
        guard started else { return }
        setRunning(screenshots.start, screenshots.stop, screenshotPreferences.autoCopy)
    }

    private func setRunning(_ start: () -> Void, _ stop: () -> Void, _ shouldRun: Bool) {
        if shouldRun { start() } else { stop() }
    }

    private func isVisible(_ module: FeatureModule) -> Bool {
        modulePreferences?.isVisible(module) ?? true
    }

    /// Lightweight services tick immediately, and so does system-wide media,
    /// which asks macOS for nothing. The permission-gated ones — Calendar, and
    /// the Apple Events half of Media — start on first expand so a brand-new
    /// user isn't hit with a wall of prompts before seeing the UI.
    func startAmbient() {
        guard !started else { return }
        started = true
        time.start()
        system.start()
        battery.start()
        focus.start()
        timers.start()
        // Gated on their module being visible — see `applyModuleVisibility`.
        if isVisible(.clipboard) { clipboard.start() }
        if isVisible(.todo) { reminders.start() }
        // Needs no permission, so the notch can show a track before the user
        // has opened anything.
        if isVisible(.media) { media.startSystemPlayback() }
        // Deliberately not module-gated — see `applyScreenshotWatching`.
        applyScreenshotWatching()
        observeActivation()

        // Time-relative activity windows advance on a slow tick rather than on
        // the 1s clock (see the forwarder above). 20s is plenty at minute-scale
        // lead times, and keeps the clock off the activity-rebuild path.
        let activityTimer = Timer(timeInterval: 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsActivityRefresh() }
        }
        RunLoop.main.add(activityTimer, forMode: .common)
        self.activityTimer = activityTimer

        prewarmMediaAnimation()
        refreshActivities()
    }

    /// Decode the astronaut animation once at launch so the first dashboard open
    /// — or the first collapsed now-playing pill — does not pay the Lottie
    /// decode. The result is cached inside `AstronautAnimation`.
    private func prewarmMediaAnimation() {
        guard isVisible(.media) else { return }
        Task { @MainActor in
            _ = await AstronautAnimation.load(.asDrawn)
            _ = await AstronautAnimation.load(.white)
        }
    }

    /// Stops everything that holds a resource beyond this process.
    ///
    /// The media adapter runs a real child process; nothing reaps it if the app
    /// exits without terminating it, so a quit would leave a stray
    /// `mediaremote-adapter` behind for every launch.
    func shutDown() {
        activityTimer?.invalidate()
        activityTimer = nil
        media.stop()
        screenshots.stop()
        clipboard.stop()
        calendar.stop()
        reminders.stop()
        timers.stop()
        battery.stop()
        system.stop()
        time.stop()
    }

    func startInteractive() {
        startedInteractive = true
        if isVisible(.media) { media.start() }
        if isVisible(.calendar) { calendar.start() }
        reminders.refreshAuthorization()
    }

    /// macOS never tells an app that its Calendar/Reminders switch changed in
    /// System Settings. Re-checking on activation is what lets a user grant
    /// access and come straight back to a working app instead of relaunching.
    private func observeActivation() {
        guard activationObserver.isEmpty else { return }
        activationObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendar.refreshAuthorization()
                self?.reminders.refreshAuthorization()
            }
        }
    }

    func refreshActivities(now: Date = .now) {
        var candidates = ActivitySnapshotFactory.calendar(
            events: calendar.events,
            now: now,
            leadMinutes: activityPreferences.calendarLeadMinutes
        )
        candidates += ActivitySnapshotFactory.reminders(
            reminders.reminders,
            now: now,
            leadMinutes: activityPreferences.reminderLeadMinutes
        )
        candidates += ActivitySnapshotFactory.timers(timers.timers, now: now)

        if let battery = ActivitySnapshotFactory.battery(
            hasBattery: battery.hasBattery,
            percent: battery.percent,
            isCharging: battery.isCharging,
            isCharged: battery.isCharged,
            minutesRemaining: battery.minutesRemaining,
            warningPercent: activityPreferences.batteryWarningPercent
        ) {
            candidates.append(battery)
        }
        if let media = ActivitySnapshotFactory.media(media.nowPlaying, isPlaying: media.isPlaying) {
            candidates.append(media)
        }
        // Only when the state was really read: a guessed "on" put a persistent
        // "Focus is on" pill in the notch on Macs where it was off.
        if let focus = ActivitySnapshotFactory.focus(isOn: focus.isStateKnown && focus.isOn) {
            candidates.append(focus)
        }

        activityCoordinator.submit(candidates, now: now)
    }
}
