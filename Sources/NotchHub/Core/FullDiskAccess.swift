import Foundation

/// Conservatively reports whether an existing Full Disk Access grant lets
/// NotchHub read protected files.
///
/// There is deliberately no API to request this, and NotchHub does not pretend
/// otherwise: every other permission it uses has a prompt, but Full Disk Access
/// is granted only by hand, in System Settings. So the result is used for one
/// thing — skipping optional thumbnail and metadata reads that would otherwise
/// trigger a folder-access prompt — and the Permissions list explains what the
/// grant buys without ever demanding it.
enum FullDiskAccess {

    /// Paths readable only with Full Disk Access, in the order they are tried.
    /// Reading one never prompts — unlike the per-folder permissions, these fail
    /// silently when absent, which is what makes them safe to probe on a timer.
    ///
    /// `com.apple.TCC/TCC.db` comes first because macOS creates it for every
    /// account: it is the one file whose presence does not depend on the user
    /// having used some feature. The Focus assertions file used to be the only
    /// probe, and on a Mac that had never switched on a Focus mode it simply did
    /// not exist — so no answer was ever reachable, granting Full Disk Access
    /// changed nothing the user could see, and the settings row could never be
    /// satisfied.
    nonisolated static let probePaths: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/DoNotDisturb/DB/Assertions.json",
        "Library/Safari/CloudTabs.db"
    ]

    nonisolated static func probeURLs(home: String = NSHomeDirectory()) -> [URL] {
        probePaths.map { URL(fileURLWithPath: home).appendingPathComponent($0) }
    }

    /// What the probe was able to tell us.
    enum Status: Equatable, Sendable {
        /// The protected file was read — the grant is definitely present.
        case granted
        /// The file exists but could not be read — the grant is definitely absent.
        case denied
        /// None of the probe files exists, so the grant cannot be established
        /// either way. With `TCC.db` in the list this should not happen on a
        /// normal account; it stays a case rather than an assumption.
        case indeterminate
    }

    /// What the probe can establish about the grant.
    ///
    /// The three cases are kept apart on purpose. An absent probe file used to
    /// be reported as granted so the settings row would not nag someone with
    /// nothing to fix — but callers that guard against *prompting* read the same
    /// answer, and acting as though access were granted is exactly what raises
    /// the per-folder dialogs they exist to avoid. The UI renders
    /// `indeterminate` neutrally; the guards treat it as "not established".
    static func status(fileManager: FileManager = .default, home: String = NSHomeDirectory()) -> Status {
        // The first probe that exists decides. A probe that is absent says
        // nothing about the grant, so it is skipped rather than counted as a
        // denial; only when none of them exists is the answer unknowable.
        for probe in probeURLs(home: home) where fileManager.fileExists(atPath: probe.path) {
            return (try? Data(contentsOf: probe)) != nil ? .granted : .denied
        }
        return .indeterminate
    }

    /// True only when the grant is established. Callers guarding against
    /// folder-permission prompts must use this, not a tri-state check.
    static func isGranted(fileManager: FileManager = .default, home: String = NSHomeDirectory()) -> Bool {
        status(fileManager: fileManager, home: home) == .granted
    }
}
