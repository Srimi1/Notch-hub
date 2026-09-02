import Foundation

/// One folder the cache cleanup can offer.
///
/// File scope, and every field a value, so a scan running in a detached task
/// can hand a list of these back to the main actor.
struct CacheCandidate: Identifiable, Equatable, Sendable {
    enum Kind: Sendable, Equatable {
        case appCache
        case developerTool
        case log
        case container
    }

    let url: URL
    /// The catalog's display name, or the folder name when the tier list
    /// recognised it instead.
    let title: String
    let level: CacheSafetyLevel
    let kind: Kind
    /// True only for a sandboxed container's `Data/Library/Caches`: its
    /// children are trashed and the folder itself stays, because the container
    /// expects it to exist. The `~/Library/Caches` and `~/Library/Logs` roots
    /// need no such flag — their children are the candidates.
    let deleteContentsOnly: Bool
    var bytes: Int64 = 0

    var id: String { url.path }
}

/// What the last scan found, in the form the panel shows and Settings keeps.
struct CacheScanSummary: Equatable, Sendable, Codable {
    var safeBytes: Int64
    var safeCount: Int
    var checkFirstBytes: Int64
    var checkFirstCount: Int
    var date: Date
    /// Whether developer caches were part of it — a summary made with the
    /// switch off is stale the moment it is turned on.
    var includedDeveloperCaches: Bool
    /// Whether sandboxed containers were entered — they are only when Full
    /// Disk Access was already granted, so a grant arriving later makes the
    /// number stale.
    var includedContainers: Bool

    /// The summary after a clean, without waiting for the rescan: what moved
    /// is no longer there to count.
    func subtracting(_ clean: CleanSummary) -> CacheScanSummary {
        var next = self
        next.safeBytes = max(0, safeBytes - clean.movedBytes)
        next.safeCount = max(0, safeCount - clean.movedCount)
        return next
    }
}

/// What a clean did. `firstFailure` is the one line the panel can show when
/// something refused to move; the rest is counts.
struct CleanSummary: Equatable, Sendable, Codable {
    var movedBytes: Int64
    var movedCount: Int
    var failedCount: Int
    var skippedCount: Int
    var firstFailure: String?
    var date: Date

    var problemCount: Int { failedCount + skippedCount }
}

struct CacheScanOutcome: Sendable {
    var candidates: [CacheCandidate] = []
    var failure: CleanupError?
    var cancelled = false
    var finishedAt: Date
}

struct CleanOutcome: Sendable {
    var summary: CleanSummary
    var attempted: Int
    var cancelled = false
}

enum CleanupError: Error, Equatable, Sendable {
    /// Listing a scan root failed for a reason other than permission.
    case folderUnreadable(folder: String, reason: String)
    /// Listing a scan root failed because macOS refused. Not expected for
    /// `~/Library/Caches`, which is not guarded, but the answer if it ever is.
    case permissionRefused(folder: String)
    /// A clean ran and moved nothing at all.
    case nothingMoved(attempted: Int, reason: String)

    var settingsPane: SystemSettingsPane? {
        switch self {
        case .permissionRefused: .fullDiskAccess
        case .folderUnreadable, .nothingMoved: nil
        }
    }

    var message: String {
        switch self {
        case let .folderUnreadable(folder, reason):
            "Could not read \(folder): \(reason)"
        case let .permissionRefused(folder):
            "macOS blocked \(folder). Allow NotchHub in \(SystemSettingsPane.fullDiskAccess.settingsPath)."
        case let .nothingMoved(_, reason):
            "Nothing could be moved: \(reason)"
        }
    }
}

/// Everything the scan and clean do to the disk, as closures the tests can
/// replace. The live versions are in `CacheCleanupLive`.
struct CacheCleanupIO: Sendable {
    /// The immediate children of a folder. Directories must come back with
    /// `hasDirectoryPath` set, which `contentsOfDirectory` does on its own.
    var enumerateTopLevel: @Sendable (URL) throws -> [URL]
    var exists: @Sendable (URL) -> Bool
    /// Bytes a folder (or file) occupies on disk. Long walks poll
    /// `isCancelled` and may return early with a partial total.
    var allocatedSize: @Sendable (URL, _ isCancelled: @Sendable () -> Bool) -> Int64
    var trash: @Sendable (URL) throws -> Void
    var fullDiskAccess: @Sendable () -> Bool

    static let live = CacheCleanupIO(
        enumerateTopLevel: { try CacheCleanupLive.contents(of: $0) },
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        allocatedSize: { CacheCleanupLive.allocatedSize(of: $0, isCancelled: $1) },
        trash: { try CacheCleanupLive.moveToTrash($0) },
        fullDiskAccess: { FullDiskAccess.isGranted() }
    )
}

enum CacheCleanupLive {

    static func contents(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    /// A sequential walk summing allocated bytes. No `du`, no subprocess:
    /// the same `FileManager` the rest of the app uses, on the caller's
    /// (detached, utility) task. Errors inside the tree are logged once per
    /// folder and the subtree skipped; a total that is a little low is better
    /// than no total.
    static func allocatedSize(of url: URL, isCancelled: @Sendable () -> Bool) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        if !url.hasDirectoryPath {
            return fileSize(url, keys: keys) ?? 0
        }
        let logged = LoggedOnce(url: url)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                logged.log(error)
                return true
            }
        ) else { return 0 }

        var total: Int64 = 0
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 512 == 0, isCancelled() { break }
            do {
                let values = try child.resourceValues(forKeys: keys)
                if values.isRegularFile == true {
                    total += Int64(values.totalFileAllocatedSize ?? 0)
                }
            } catch {
                logged.log(error)
            }
        }
        return total
    }

    private static func fileSize(_ url: URL, keys: Set<URLResourceKey>) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: keys)
            return Int64(values.totalFileAllocatedSize ?? 0)
        } catch {
            NSLog("NotchHub cleanup: could not size %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    /// Same two lines as the screenshot watcher: recoverable by design.
    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// One log line per folder, however many files inside it fail. A cache
    /// with a thousand unreadable entries is one fact, not a thousand.
    private final class LoggedOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let url: URL

        init(url: URL) { self.url = url }

        func log(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            NSLog("NotchHub cleanup: skipped part of %@: %@", url.path, error.localizedDescription)
        }
    }
}

/// `~/Library/Caches` rather than the full path, for captions and logs.
func abbreviatingHome(_ url: URL, home: URL) -> String {
    let homePath = home.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(homePath + "/") else { return path }
    return "~" + path.dropFirst(homePath.count)
}
