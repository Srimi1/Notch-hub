import AppKit

/// The System Settings panes NotchHub sends people to when a permission has to
/// be granted by hand.
///
/// Each failure mode deserves its own destination: telling someone to check
/// Accessibility when macOS actually blocked an Apple Event — or when what they
/// declined was Calendar — sends them to a list where NotchHub is already
/// ticked, or not listed at all, and they conclude the app is broken.
enum SystemSettingsPane: String, CaseIterable {
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case fullDiskAccess = "Privacy_AllFiles"
    case calendar = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"
    case notifications = "notifications"

    /// Notifications is not part of Privacy & Security; it is its own settings
    /// extension, so it needs a different URL entirely.
    private static let securityDomain = "com.apple.preference.security"
    private static let notificationsURL =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    var url: URL? {
        switch self {
        case .notifications: URL(string: Self.notificationsURL)
        default: URL(string: "x-apple.systempreferences:\(Self.securityDomain)?\(rawValue)")
        }
    }

    /// Opens the pane in System Settings.
    ///
    /// Returns false when the URL could not be opened, so callers can say so
    /// rather than leaving the user waiting for a window that never arrives.
    @discardableResult
    func open() -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Where to find the switch, for the sentence shown next to the button.
    var settingsPath: String {
        switch self {
        case .accessibility: "System Settings ▸ Privacy & Security ▸ Accessibility"
        case .automation: "System Settings ▸ Privacy & Security ▸ Automation"
        case .fullDiskAccess: "System Settings ▸ Privacy & Security ▸ Full Disk Access"
        case .calendar: "System Settings ▸ Privacy & Security ▸ Calendars"
        case .reminders: "System Settings ▸ Privacy & Security ▸ Reminders"
        case .notifications: "System Settings ▸ Notifications"
        }
    }
}
