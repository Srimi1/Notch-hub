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
    let purgePrivilege = PurgePrivilege()
    let memoryCleaner: MemoryCleanerService
    let battery = BatteryService()
    let media = MediaService()
    let calendar = CalendarService()
    let clipboard = ClipboardService()
    let focus = FocusService()
    let aiCoding = AICodingService()
    let reminders = ReminderService()
    let timers = ActivityTimerService()
    let activityPreferences = ActivityPreferences()
    let activityCoordinator: ActivityCoordinator

    /// Non-secret credit-tracker config (Grok team ID, probe toggle). Keys live
    /// only in the Keychain, never here.
    let creditPrefs = CreditPreferences()
    /// Adaptive API-key credit/spend tracker backing the AI Coding tab.
    let credit: CreditTrackerService

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    /// Owns the activation observer so it is unregistered when the hub goes
    /// away. Deregistering from `ServiceHub.deinit` directly would mean touching
    /// main-actor state from a nonisolated deinit, which is an error under
    /// Swift 6; a plain box has no such isolation to violate.
    private let activationObserver = NotificationObserverToken()

    init() {
        memoryCleaner = MemoryCleanerService(privilege: purgePrivilege)
        credit = CreditTrackerService(prefs: creditPrefs)
        activityCoordinator = ActivityCoordinator(preferences: activityPreferences)

        // Re-publish whenever any child service changes, so container views
        // that switch on cross-service state (the live strip, the collapsed
        // wing selector) stay reactive without observing each child directly.
        let forward: () -> Void = { [weak self] in self?.objectWillChange.send() }
        let publishers: [ObservableObjectPublisher] = [
            time.objectWillChange, system.objectWillChange, battery.objectWillChange,
            media.objectWillChange, calendar.objectWillChange,
            clipboard.objectWillChange, focus.objectWillChange, aiCoding.objectWillChange,
            memoryCleaner.objectWillChange, purgePrivilege.objectWillChange
        ]
        for publisher in publishers {
            publisher
                .sink { [weak self] in
                    forward()
                    Task { @MainActor [weak self] in self?.refreshActivities() }
                }
                .store(in: &cancellables)
        }

        timers.onChange = { [weak self] in self?.refreshActivities() }
        reminders.onChange = { [weak self] in self?.refreshActivities() }
        activityPreferences.onChange = { [weak self] in
            self?.activityCoordinator.refreshForPreferences()
            self?.refreshActivities()
        }
    }

    /// Lightweight services tick immediately; permission-gated ones
    /// (calendar, AppleScript media) start on first expand so a brand-new user
    /// isn't hit with a wall of prompts before seeing the UI.
    func startAmbient() {
        guard !started else { return }
        started = true
        time.start()
        system.start()
        battery.start()
        clipboard.start()
        focus.start()
        aiCoding.start()
        timers.start()
        reminders.start()
        credit.start()
        purgePrivilege.refresh()
        observeActivation()
        refreshActivities()
    }

    func startInteractive() {
        media.start()
        calendar.start()
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

    func stopInteractive() {
        media.stop()
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
        if let focus = ActivitySnapshotFactory.focus(isOn: focus.isOn) {
            candidates.append(focus)
        }

        activityCoordinator.submit(candidates, now: now)
    }
}
