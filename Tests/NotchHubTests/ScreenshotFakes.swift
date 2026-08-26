import Foundation
import Testing
@testable import NotchHub

// Fakes for the screenshot watcher's collaborators.
//
// They live here rather than beside one suite because the service tests and
// any future suite over the same seams both need them, and because lifting them
// out keeps `ScreenshotServiceTests` under the 300-line type-body cap.
//
// `@unchecked Sendable` throughout, each guarded by its own lock: the service
// hands these `@Sendable` closures that it calls from a detached scan task,
// while the tests read them from the main actor.

/// Stands in for the real descriptor watch. Locked because the service
/// hands it a `@Sendable` callback and the test fires it from the main
/// actor; nothing here is touched concurrently in practice.
final class FakeWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (DirectoryChange) -> Void)?
    private var armedFolders: [URL] = []
    private var stops = 0

    func start(_ url: URL, onChange: @escaping @Sendable (DirectoryChange) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        callback = onChange
        armedFolders.append(url)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        stops += 1
    }

    func fire(_ change: DirectoryChange) {
        lock.lock()
        let handler = callback
        lock.unlock()
        handler?(change)
    }

    var armed: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return armedFolders
    }

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }
}

/// What the folder appears to contain and what each file turns out to be.
final class Stage: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ScreenshotScanPolicy.Entry] = []
    private var verdicts: [String: ScreenshotClassifier.Verdict] = [:]
    private var trashed: [URL] = []
    private var events: [String] = []
    private var location = ScreenshotLocation(
        folder: URL(fileURLWithPath: "/fixtures/Desktop", isDirectory: true), format: .png
    )
    var access: ScreenshotAccess = .allowed

    func stage(_ name: String, verdict: ScreenshotClassifier.Verdict, at moment: Date) {
        lock.lock()
        defer { lock.unlock() }
        let url = URL(fileURLWithPath: "/fixtures/Desktop/\(name)")
        entries = [ScreenshotScanPolicy.Entry(url: url, modified: moment, size: 4096)]
        verdicts[url.path] = verdict
    }

    func resolve(_ name: String, to verdict: ScreenshotClassifier.Verdict) {
        lock.lock()
        defer { lock.unlock() }
        verdicts["/fixtures/Desktop/\(name)"] = verdict
    }

    func move(to folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        location = ScreenshotLocation(folder: folder, format: .png)
    }

    func list(_: URL) throws -> [ScreenshotScanPolicy.Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func classify(_ url: URL) -> ScreenshotClassifier.Verdict {
        lock.lock()
        defer { lock.unlock() }
        events.append("classify:\(url.lastPathComponent)")
        return verdicts[url.path] ?? .notAScreenshot
    }

    func trash(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        events.append("trash:\(url.lastPathComponent)")
        trashed.append(url)
    }

    func note(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var currentLocation: ScreenshotLocation {
        lock.lock()
        defer { lock.unlock() }
        return location
    }

    var trashedFiles: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return trashed
    }

    var log: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var classifyCount: Int { log.filter { $0.hasPrefix("classify:") }.count }
}

final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CapturedScreenshot] = []
    func append(_ value: CapturedScreenshot) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var all: [CapturedScreenshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
