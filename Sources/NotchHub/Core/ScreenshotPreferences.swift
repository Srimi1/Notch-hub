import Foundation
import Observation

/// Switches for screenshot auto-copy.
///
/// Deliberately not part of `HudPreferences`, whose own comment scopes it to
/// "moments, not modules": a filesystem watcher holding a folder grant from
/// macOS is neither. Keeping it separate also keeps the grant list — the set of
/// folders the user has already been asked about — next to the switch that
/// causes the asking.
@MainActor
@Observable
final class ScreenshotPreferences {
    private enum Key {
        static let autoCopy = "screenshot.autoCopy"
        static let trashAfterCopying = "screenshot.trashAfterCopying"
        static let allowedFolders = "screenshot.allowedFolders"
    }

    /// How many folders are remembered as allowed. People change the
    /// screenshot location rarely; an unbounded list persisted from disk is an
    /// unbounded thing to validate on every launch.
    static let allowedFolderLimit = 8

    /// Off until the user asks for it. Turning it on is what raises the macOS
    /// folder dialog, so it must never be on by default — a background app with
    /// no window cannot explain a permission prompt at login.
    var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Key.autoCopy); onChange?() }
    }

    /// Whether the file macOS saved is moved to the Trash once the picture is
    /// safely on the pasteboard. Off by default: reading a folder and deleting
    /// inside it are different sizes of trust.
    var trashAfterCopying: Bool {
        didSet { defaults.set(trashAfterCopying, forKey: Key.trashAfterCopying); onChange?() }
    }

    /// Folders the user has already been asked about. The watcher only ever
    /// arms on a folder in this set, which is what keeps the TCC dialog tied to
    /// the button that asks for it rather than to app launch.
    private(set) var allowedFolders: [String] {
        didSet { defaults.set(allowedFolders, forKey: Key.allowedFolders) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoCopy = defaults.object(forKey: Key.autoCopy) as? Bool ?? false
        trashAfterCopying = defaults.object(forKey: Key.trashAfterCopying) as? Bool ?? false
        allowedFolders = Self.validated(defaults.array(forKey: Key.allowedFolders) as? [String] ?? [])
    }

    func isAllowed(_ url: URL) -> Bool {
        allowedFolders.contains(Self.identity(of: url))
    }

    func allow(_ url: URL) {
        let path = Self.identity(of: url)
        guard !allowedFolders.contains(path) else { return }
        allowedFolders = Array((allowedFolders + [path]).suffix(Self.allowedFolderLimit))
    }

    func forget(_ url: URL) {
        let path = Self.identity(of: url)
        guard allowedFolders.contains(path) else { return }
        allowedFolders.removeAll { $0 == path }
    }

    /// One spelling per folder. `~/Desktop` and `~/Desktop/` are the same
    /// grant, and a relative path is not a folder identity at all.
    static func identity(of url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Stored paths are external data by the time they come back: a defaults
    /// domain is a file anything running as the user can write. Keep only
    /// absolute, plausible paths, deduplicated and bounded.
    static func validated(_ stored: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for path in stored where path.hasPrefix("/") && !path.isEmpty {
            let identity = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(identity).inserted else { continue }
            kept.append(identity)
        }
        return Array(kept.suffix(allowedFolderLimit))
    }
}
