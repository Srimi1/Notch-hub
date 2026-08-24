import AppKit

/// Reports whether NotchHub has Full Disk Access, and opens the one place a
/// user can grant it.
///
/// There is deliberately no API to request this. Every other permission the app
/// uses has one — EventKit prompts, Apple Events prompts — but Full Disk Access
/// is granted only by the user, by hand, in System Settings. An app that could
/// award itself the right to read every file on the disk would defeat the point
/// of the setting, so this type does the only two things an app legitimately
/// can: notice the current state, and take the user to the switch.
///
/// Why it is worth granting: without it, macOS asks separately for each
/// protected folder — Desktop, Documents, Downloads, iCloud Drive — the first
/// time NotchHub reads a file copied out of one. Full Disk Access answers all of
/// those at once, permanently.
enum FullDiskAccess {

    /// A path readable only with Full Disk Access. Reading it never prompts —
    /// unlike the per-folder permissions, this one fails silently when absent,
    /// which is what makes it safe to probe on a timer.
    private static let probe = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// True when the app can read protected locations.
    ///
    /// A missing file is treated as "granted": on a Mac that has never used a
    /// Focus mode the probe simply does not exist, and reporting that as denied
    /// would nag a user who has nothing to fix.
    static func isGranted(fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: probe.path) else { return true }
        return (try? Data(contentsOf: probe)) != nil
    }

    /// Open System Settings ▸ Privacy & Security ▸ Full Disk Access.
    ///
    /// Returns false if the pane could not be opened, so the caller can say so
    /// rather than leaving the user waiting for a window that never arrives.
    @discardableResult
    static func openSettingsPane() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
