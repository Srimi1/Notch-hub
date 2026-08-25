import Foundation

/// Conservatively reports whether an existing Full Disk Access grant lets
/// NotchHub read protected files. The app never asks for this broad permission;
/// it uses the result only to avoid optional thumbnail and metadata reads that
/// could otherwise trigger a folder-access prompt.
enum FullDiskAccess {

    /// A path readable only with Full Disk Access. Reading it never prompts —
    /// unlike the per-folder permissions, this one fails silently when absent,
    /// which is what makes it safe to probe on a timer.
    private static let probe = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// True only when a protected probe exists and can be read. A missing probe
    /// proves nothing about the grant, so it is treated as unavailable.
    static func isGranted(fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: probe.path) else { return false }
        return (try? Data(contentsOf: probe)) != nil
    }
}
