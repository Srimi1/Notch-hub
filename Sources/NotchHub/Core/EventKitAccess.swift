@preconcurrency import EventKit

/// What NotchHub should do for a given EventKit authorization status.
///
/// macOS posts no notification when the user changes an app's Calendar or
/// Reminders switch in System Settings, so `CalendarService` and
/// `ReminderService` re-read the status on their refresh tick and on app
/// activation. Keeping the decision here makes that state machine testable
/// without touching a real `EKEventStore`.
enum EventKitAccessDecision: Equatable, Sendable {
    /// Full read access — load data.
    case granted
    /// No usable read access — surface an honest, actionable error.
    case denied
    /// The user has never been asked — show the system prompt.
    case needsPrompt

    static func decide(for status: EKAuthorizationStatus) -> EventKitAccessDecision {
        switch status {
        case .authorized, .fullAccess:
            return .granted
        case .notDetermined:
            return .needsPrompt
        case .denied, .restricted, .writeOnly:
            // `writeOnly` can add items but cannot read them, so every NotchHub
            // feature that lists events or reminders is unavailable.
            return .denied
        @unknown default:
            return .denied
        }
    }
}
