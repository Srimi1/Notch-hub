import Foundation
import Observation

/// Switches for the cache cleanup in the Focus panel, plus the last scan and
/// clean so the panel has a number to show before it has scanned again.
///
/// Its own type rather than a corner of `HudPreferences`, whose comment scopes
/// that to "moments, not modules": this is a control that lives in a module
/// and a scan that touches the disk.
@MainActor
@Observable
final class CleanupPreferences {
    private enum Key {
        static let showInFocus = "cleanup.showInFocus"
        static let includeDeveloperCaches = "cleanup.includeDeveloperCaches"
        static let lastScan = "cleanup.lastScan"
        static let lastClean = "cleanup.lastClean"
    }

    /// On by default. Unlike the screenshot watcher this raises no macOS
    /// prompt and changes nothing on disk until the button is clicked; the
    /// scan only reads folders that are not permission-guarded.
    var showInFocus: Bool {
        didSet { defaults.set(showInFocus, forKey: Key.showInFocus); onChange?() }
    }

    /// Off by default. Xcode, npm and Homebrew caches are large and, for a
    /// developer, worth a moment's thought; for everyone else they do not exist.
    var includeDeveloperCaches: Bool {
        didSet { defaults.set(includeDeveloperCaches, forKey: Key.includeDeveloperCaches); onChange?() }
    }

    private(set) var lastScan: CacheScanSummary? {
        didSet { Self.store(lastScan, forKey: Key.lastScan, in: defaults) }
    }

    private(set) var lastClean: CleanSummary? {
        didSet { Self.store(lastClean, forKey: Key.lastClean, in: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        showInFocus = defaults.object(forKey: Key.showInFocus) as? Bool ?? true
        includeDeveloperCaches = defaults.object(forKey: Key.includeDeveloperCaches) as? Bool ?? false
        lastScan = Self.validated(Self.load(CacheScanSummary.self, forKey: Key.lastScan, from: defaults), now: now)
        lastClean = Self.validated(Self.load(CleanSummary.self, forKey: Key.lastClean, from: defaults), now: now)
    }

    func recordScan(_ summary: CacheScanSummary) {
        lastScan = summary
    }

    func recordClean(_ summary: CleanSummary) {
        lastClean = summary
    }

    // MARK: - Validation

    /// A stored summary is external data by the time it comes back — a
    /// defaults domain is a file anything running as the user can write. A
    /// negative count or a date in the future is not a summary.
    static func validated(_ summary: CacheScanSummary?, now: Date) -> CacheScanSummary? {
        guard let summary,
              summary.safeBytes >= 0, summary.safeCount >= 0,
              summary.checkFirstBytes >= 0, summary.checkFirstCount >= 0,
              summary.date <= now
        else { return nil }
        return summary
    }

    static func validated(_ summary: CleanSummary?, now: Date) -> CleanSummary? {
        guard let summary,
              summary.movedBytes >= 0, summary.movedCount >= 0,
              summary.failedCount >= 0, summary.skippedCount >= 0,
              summary.date <= now
        else { return nil }
        return summary
    }

    // MARK: - Storage

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("NotchHub cleanup: discarding stored %@: %@", key, error.localizedDescription)
            return nil
        }
    }

    private static func store(_ value: (some Encodable)?, forKey key: String, in defaults: UserDefaults) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("NotchHub cleanup: could not store %@: %@", key, error.localizedDescription)
        }
    }
}
