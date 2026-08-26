import Foundation
import Testing
@testable import NotchHub

/// The only suite here that touches a real filesystem, because a file
/// descriptor and a GCD event source are exactly what it is pinning. It works
/// in a throwaway temporary directory and never goes near the Desktop, so no
/// permission dialog can be involved.
///
/// This is the suite `NOTCHHUB_TSAN=1 ./scripts/check.sh` runs, alongside the
/// adapter's. Descriptor ownership is the rule it exists to protect.
@Suite("Directory watcher")
struct DirectoryWatcherTests {

    /// Records what the watcher reported. Locked because the callback arrives
    /// on the watcher's own queue and the assertions read from the test's.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [DirectoryChange] = []

        func record(_ change: DirectoryChange) {
            lock.lock()
            defer { lock.unlock() }
            changes.append(change)
        }

        var all: [DirectoryChange] {
            lock.lock()
            defer { lock.unlock() }
            return changes
        }

        var count: Int { all.count }
    }

    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchHubTests." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ name: String, in directory: URL) throws {
        try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
    }

    /// Filesystem events are genuinely asynchronous, so this waits on the real
    /// thing rather than yielding — but it is bounded, so a broken watcher
    /// fails the test instead of hanging the suite.
    private static func wait(
        upTo seconds: TimeInterval = 3,
        until condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// The whole point: a new file has to reach the service, or no screenshot
    /// is ever copied.
    @Test
    func aFileAppearingInTheWatchedDirectoryIsReported() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Log()
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }

        watcher.start(directory) { log.record($0) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try Self.write("shot.png", in: directory)

        #expect(await Self.wait { log.all.contains(.changed) })
    }

    /// The regression this exists for: a descriptor closed by anything other
    /// than the source's cancel handler, or an event handler still running
    /// after `stop()`, is a use-after-close. Silence after stopping is the
    /// observable half of that guarantee; the sanitizer checks the rest.
    @Test
    func stoppingTheWatchEndsTheCallbacks() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Log()
        let watcher = DirectoryWatcher()

        watcher.start(directory) { log.record($0) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try Self.write("first.png", in: directory)
        _ = await Self.wait { !log.all.isEmpty }

        watcher.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let settled = log.count
        try Self.write("second.png", in: directory)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(log.count == settled)
    }

    /// Arming twice must leave exactly one watch, not two descriptors on the
    /// same folder — the second of which nothing would ever close.
    @Test
    func startingTwiceLeavesOnlyOneWatch() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Log()
        let watcher = DirectoryWatcher()

        watcher.start(directory) { log.record($0) }
        watcher.start(directory) { log.record($0) }
        try await Task.sleep(nanoseconds: 150_000_000)
        watcher.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let settled = log.count

        try Self.write("shot.png", in: directory)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(log.count == settled)
    }

    /// `stop()` before `start()` must not turn into `close(-1)`.
    @Test
    func stoppingBeforeStartingIsHarmless() async {
        let watcher = DirectoryWatcher()

        watcher.stop()
        watcher.stop()

        #expect(await Self.wait(upTo: 0.2) { true })
    }

    /// A folder that is deleted has to be reported, not silently watched
    /// forever: the descriptor still refers to the old inode, so the service
    /// needs to know to re-arm by path.
    @Test
    func deletingTheWatchedDirectoryIsReported() async throws {
        let directory = try Self.makeDirectory()
        let log = Log()
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }

        watcher.start(directory) { log.record($0) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try FileManager.default.removeItem(at: directory)

        #expect(await Self.wait { log.all.contains(.vanished) })
    }

    /// A location that does not exist has to come back as a failure the
    /// service can show, rather than a watch that never fires.
    @Test
    func watchingSomethingThatIsNotThereFails() async {
        let log = Log()
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }

        watcher.start(URL(fileURLWithPath: "/nope/not/here")) { log.record($0) }

        #expect(await Self.wait { log.all.contains { if case .failed = $0 { true } else { false } } })
    }
}
