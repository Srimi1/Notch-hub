import AppKit
import ApplicationServices
import EventKit
import Foundation
import Observation
import UserNotifications

/// Where a permission stands right now.
enum PermissionStatus: Equatable, Sendable {
    /// NotchHub has it.
    case granted
    /// The user said no, or the system withholds it.
    case denied
    /// Nobody has asked yet — a prompt would work.
    case notDetermined
    /// It cannot be established from inside the app.
    case unknown

    var isGranted: Bool { self == .granted }
}

/// One place that knows what NotchHub needs from macOS, what it has, and how to
/// ask for the rest.
///
/// macOS deliberately gives no way for an app to award itself Accessibility,
/// Full Disk Access, or Automation. So "all permissions by default" is, at
/// most: ask for everything askable at a moment the user expects it, and take
/// them straight to the switch for the rest. Doing that up front — instead of
/// leaving each feature to fail quietly the first time it is used — is what
/// this type exists for.
@MainActor
@Observable
final class PermissionCenter {

    enum Permission: String, CaseIterable, Identifiable, Sendable {
        case accessibility
        case automation
        case calendar
        case reminders
        case notifications
        case fullDiskAccess

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .automation: "Automation"
            case .calendar: "Calendar"
            case .reminders: "Reminders"
            case .notifications: "Notifications"
            case .fullDiskAccess: "Full Disk Access"
            }
        }

        var symbol: String {
            switch self {
            case .accessibility: "hand.tap"
            case .automation: "gearshape.2"
            case .calendar: "calendar"
            case .reminders: "checklist"
            case .notifications: "bell.badge"
            case .fullDiskAccess: "externaldrive"
            }
        }

        /// What NotchHub loses without it — stated as a feature, not a warning.
        var explanation: String {
            switch self {
            case .accessibility:
                "Toggle Do Not Disturb, and paste a clip straight into the app you're using."
            case .automation:
                "Read and control what's playing in your music apps."
            case .calendar:
                "Show your next event in the notch."
            case .reminders:
                "Show what's due and let you tick it off from the notch."
            case .notifications:
                "Tell you when a timer finishes."
            case .fullDiskAccess:
                "Preview files you copy without macOS asking folder by folder."
            }
        }

        /// Whether macOS offers a prompt for this one. Full Disk Access has no
        /// API at all — the switch is the only way.
        var isPromptable: Bool { self != .fullDiskAccess }

        /// Where the user grants it by hand when the prompt is spent.
        ///
        /// Every one of these has to be the pane holding the actual switch.
        /// Calendar, Reminders and Notifications used to fall back to
        /// Accessibility, which has no switch for any of them — the button
        /// dropped the user on a list where NotchHub was already ticked, and
        /// a declined Calendar prompt became unrecoverable from inside the app.
        var settingsPane: SystemSettingsPane {
            switch self {
            case .accessibility: .accessibility
            case .automation: .automation
            case .fullDiskAccess: .fullDiskAccess
            case .calendar: .calendar
            case .reminders: .reminders
            case .notifications: .notifications
            }
        }
    }

    /// How statuses are read. Injected so tests never touch real TCC state —
    /// and because `UNUserNotificationCenter` traps in an unbundled process.
    struct Probes: Sendable {
        var accessibility: @Sendable () -> PermissionStatus
        var automation: @Sendable () -> PermissionStatus
        var calendar: @Sendable () -> PermissionStatus
        var reminders: @Sendable () -> PermissionStatus
        var notifications: @Sendable () async -> PermissionStatus
        var fullDiskAccess: @Sendable () -> PermissionStatus

        static let live = Probes(
            accessibility: { AXIsProcessTrusted() ? .granted : .denied },
            automation: { PermissionCenter.automationStatus(askUserIfNeeded: false) },
            calendar: { PermissionCenter.eventKitStatus(EKEventStore.authorizationStatus(for: .event)) },
            reminders: { PermissionCenter.eventKitStatus(EKEventStore.authorizationStatus(for: .reminder)) },
            notifications: { await PermissionCenter.notificationStatus() },
            fullDiskAccess: {
                switch FullDiskAccess.status() {
                case .granted: .granted
                case .denied: .denied
                case .indeterminate: .unknown
                }
            }
        )
    }

    /// How prompts are raised. The EventKit ones belong to the services that
    /// own the stores, so they arrive as closures rather than being duplicated.
    struct Requests {
        var accessibility: () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        var automation: () -> Void = {
            // Blocking call — it can put up a dialog — so keep it off the main
            // actor and let the activation refresh pick the answer up.
            Task.detached(priority: .userInitiated) {
                _ = PermissionCenter.automationStatus(askUserIfNeeded: true)
            }
        }

        var calendar: () -> Void = {}
        var reminders: () -> Void = {}
        var notifications: () -> Void = {
            Task {
                do {
                    _ = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])
                } catch {
                    NSLog("NotchHub: notification authorization failed: \(error.localizedDescription)")
                }
            }
        }

        /// Taking the user to the switch, for the permissions (and the states)
        /// where no prompt will ever appear again.
        var openPane: (SystemSettingsPane) -> Void = { $0.open() }

        /// Wires the EventKit prompts to the live services.
        @MainActor
        static func live(services: ServiceHub) -> Requests {
            var requests = Requests()
            requests.calendar = { MainActor.assumeIsolated { services.calendar.requestAccess() } }
            requests.reminders = { Task { @MainActor in await services.reminders.requestAccess() } }
            return requests
        }
    }

    private enum Key {
        static let onboardingCompleted = "permissions.onboardingCompleted"
    }

    private(set) var statuses: [Permission: PermissionStatus] = [:]

    @ObservationIgnored private let probes: Probes
    @ObservationIgnored private let requests: Requests
    @ObservationIgnored private let defaults: UserDefaults

    init(
        probes: Probes = .live,
        requests: Requests = Requests(),
        defaults: UserDefaults = .standard
    ) {
        self.probes = probes
        self.requests = requests
        self.defaults = defaults
    }

    func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Everything NotchHub still needs, in display order.
    var outstanding: [Permission] {
        Permission.allCases.filter { status(of: $0) != .granted }
    }

    func refreshAll() async {
        var next: [Permission: PermissionStatus] = [
            .accessibility: probes.accessibility(),
            .automation: probes.automation(),
            .calendar: probes.calendar(),
            .reminders: probes.reminders(),
            .fullDiskAccess: probes.fullDiskAccess()
        ]
        next[.notifications] = await probes.notifications()
        statuses = next
    }

    /// Raise the prompt where one exists; otherwise open the pane holding the
    /// switch. Either way the user ends up somewhere they can actually act.
    func request(_ permission: Permission) {
        guard permission.isPromptable else {
            requests.openPane(permission.settingsPane)
            return
        }
        // A spent prompt never shows again, so a denial has to fall through to
        // the pane or the button would do nothing at all.
        if status(of: permission) == .denied {
            requests.openPane(permission.settingsPane)
        }
        switch permission {
        case .accessibility: requests.accessibility()
        case .automation: requests.automation()
        case .calendar: requests.calendar()
        case .reminders: requests.reminders()
        case .notifications: requests.notifications()
        case .fullDiskAccess: break
        }
    }

    // MARK: - Onboarding

    var shouldShowOnboarding: Bool {
        !defaults.bool(forKey: Key.onboardingCompleted)
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: Key.onboardingCompleted)
    }

    // MARK: - Live probes

    /// Whether NotchHub may drive System Events, which is what the Focus toggle
    /// and the media scripts ride on.
    nonisolated static func automationStatus(askUserIfNeeded: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        var descriptor = target.aeDesc?.pointee ?? AEDesc()
        let status = AEDeterminePermissionToAutomateTarget(
            &descriptor,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        // -1744: consent has not been asked for yet. -600: System Events is not
        // running, which says nothing about the grant either way.
        case -1744: return .notDetermined
        case OSStatus(procNotFound): return .unknown
        default: return .unknown
        }
    }

    nonisolated static func eventKitStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch EventKitAccessDecision.decide(for: status) {
        case .granted: .granted
        case .denied: .denied
        case .needsPrompt: .notDetermined
        }
    }

    nonisolated static func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}
