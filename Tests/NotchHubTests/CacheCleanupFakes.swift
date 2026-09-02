import Foundation
import Testing
@testable import NotchHub

// Fakes for the cache cleanup's disk seams.
//
// The suite never touches a real folder — least of all `~/Library/Caches`,
// which is the one place a bug here would be unrecoverable. Everything the
// service can do to the disk arrives as a closure, so the stage below *is* the
// filesystem as far as the tests are concerned.
//
// `@unchecked Sendable` behind a lock, like `ScreenshotFakes`: the service
// calls these from a detached scan task while the test reads them from the
// main actor.

/// A pretend home folder: what each directory contains, what each path
/// measures, and what happens when something is trashed.
final class CleanupStage: @unchecked Sendable {
    static let home = URL(fileURLWithPath: "/fixtures/home", isDirectory: true)

    private let lock = NSLock()
    private var listings: [String: [URL]] = [:]
    private var listingErrors: [String: NSError] = [:]
    private var sizes: [String: Int64] = [:]
    private var existing: Set<String> = []
    private var trashedPaths: [URL] = []
    private var failingTrash: Set<String> = []
    private var sized: [String] = []
    private var hasFullDiskAccess = false

    init(fullDiskAccess: Bool = false) {
        hasFullDiskAccess = fullDiskAccess
    }

    // MARK: - Staging

    /// Put a folder under `~/Library/Caches` with a size.
    func cache(_ name: String, megabytes: Int) {
        add(child: name, of: "Library/Caches", isDirectory: true, bytes: Int64(megabytes) * 1024 * 1024)
    }

    func log(_ name: String, megabytes: Int) {
        add(child: name, of: "Library/Logs", isDirectory: true, bytes: Int64(megabytes) * 1024 * 1024)
    }

    /// A developer cache at a home-relative path, e.g. `.npm/_cacache`.
    func developerCache(_ relativePath: String, megabytes: Int) {
        let url = Self.home.appendingPathComponent(relativePath, isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        existing.insert(url.standardizedFileURL.path)
        sizes[url.standardizedFileURL.path] = Int64(megabytes) * 1024 * 1024
    }

    /// A sandboxed container whose cache folder holds `children`.
    func container(_ bundleID: String, megabytes: Int, children: [String] = ["Cache.db"]) {
        add(child: bundleID, of: "Library/Containers", isDirectory: true, bytes: 0)
        let caches = Self.home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Caches", isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        existing.insert(caches.standardizedFileURL.path)
        sizes[caches.standardizedFileURL.path] = Int64(megabytes) * 1024 * 1024
        listings[caches.standardizedFileURL.path] = children.map {
            caches.appendingPathComponent($0, isDirectory: false)
        }
    }

    /// Make listing a folder fail — a permission refusal, or anything else.
    func failListing(_ relativePath: String, with error: NSError) {
        let path = Self.home.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        listingErrors[path] = error
    }

    /// Make trashing one path throw.
    func failTrash(of url: URL) {
        lock.lock()
        defer { lock.unlock() }
        failingTrash.insert(url.standardizedFileURL.path)
    }

    private func add(child name: String, of relativeParent: String, isDirectory: Bool, bytes: Int64) {
        let parent = Self.home.appendingPathComponent(relativeParent, isDirectory: true)
        let url = parent.appendingPathComponent(name, isDirectory: isDirectory)
        lock.lock()
        defer { lock.unlock() }
        listings[parent.standardizedFileURL.path, default: []].append(url)
        existing.insert(url.standardizedFileURL.path)
        sizes[url.standardizedFileURL.path] = bytes
    }

    // MARK: - Reading back

    var trashed: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return trashedPaths
    }

    var sizedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sized
    }

    func url(_ relativePath: String) -> URL {
        Self.home.appendingPathComponent(relativePath, isDirectory: true)
    }

    // MARK: - The seams

    func io() -> CacheCleanupIO {
        CacheCleanupIO(
            enumerateTopLevel: { [self] url in try list(url) },
            exists: { [self] url in exists(url) },
            allocatedSize: { [self] url, _ in size(of: url) },
            trash: { [self] url in try trash(url) },
            fullDiskAccess: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return hasFullDiskAccess
            }
        )
    }

    private func list(_ url: URL) throws -> [URL] {
        let path = url.standardizedFileURL.path
        lock.lock()
        let error = listingErrors[path]
        let children = listings[path]
        lock.unlock()
        if let error { throw error }
        guard let children else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        return children
    }

    private func exists(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return existing.contains(url.standardizedFileURL.path)
    }

    private func size(of url: URL) -> Int64 {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        sized.append(path)
        return sizes[path] ?? 0
    }

    /// A successful trash really removes the item from the stage, so a rescan
    /// afterwards sees what the user would see.
    private func trash(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        lock.lock()
        let fails = failingTrash.contains(path)
        if !fails {
            trashedPaths.append(url)
            existing.remove(path)
            sizes.removeValue(forKey: path)
            listings.removeValue(forKey: path)
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            listings[parent]?.removeAll { $0.standardizedFileURL.path == path }
        }
        lock.unlock()
        if fails {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "the folder is in use"]
            )
        }
    }
}

/// Records what the service asked to be scheduled instead of running it, so a
/// six-second hold does not become a six-second test.
final class ScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(delay: TimeInterval, work: @Sendable () -> Void)] = []

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return pending.map(\.delay)
    }

    func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending.append((delay, work))
        lock.unlock()
    }

    /// Run everything queued so far.
    func fire() {
        lock.lock()
        let due = pending
        pending.removeAll()
        lock.unlock()
        due.forEach { $0.work() }
    }
}

/// A clock the cleanup tests move by hand. (`TestClock` is taken by the
/// activity suite, and it is a `struct` with a settable date rather than a
/// locked reference the detached scan task can read.)
final class CleanupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_756_000_000)) {
        current = start
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

// MARK: - Shared rig

/// A service, its preferences, and the defaults suite to tear down. Shared by
/// both cleanup suites so neither carries the setup in its own body.
@MainActor
struct CleanupRig {
    let service: CacheCleanupService
    let preferences: CleanupPreferences
    let suite: String

    init?(
        stage: CleanupStage,
        clock: CleanupClock = CleanupClock(),
        recorder: ScheduleRecorder = ScheduleRecorder(),
        developerCaches: Bool = false,
        showInFocus: Bool = true
    ) {
        let suite = "CacheCleanupTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let preferences = CleanupPreferences(defaults: defaults)
        preferences.showInFocus = showInFocus
        preferences.includeDeveloperCaches = developerCaches
        self.suite = suite
        self.preferences = preferences
        service = CacheCleanupService(
            preferences: preferences,
            io: stage.io(),
            home: CleanupStage.home,
            now: { clock.date },
            schedule: { delay, work in recorder.schedule(delay, work) }
        )
    }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// The scan runs in a detached task; this lets it finish and its answer
    /// land back on the main actor.
    func settle() async {
        for _ in 0 ..< 60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The summary behind a settled state, if the scan has finished.
    func summary() -> CacheScanSummary? {
        switch service.state {
        case let .ready(summary), let .tidy(summary): summary
        default: nil
        }
    }
}
