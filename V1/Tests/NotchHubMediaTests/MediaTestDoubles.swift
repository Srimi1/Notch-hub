import Foundation
@testable import NotchHubMedia

enum TestAdapterLaunchError: Error {
    case forced
}

final class FakeAdapterHandle: AdapterProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var terminations = 0

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminationCount: Int {
        lock.withLock { terminations }
    }

    func terminate() {
        lock.withLock {
            terminations += 1
            running = false
        }
    }

    func recordExit() {
        lock.withLock { running = false }
    }
}

final class FakeAdapterLauncher: AdapterLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var streamLaunchValues: [[String]] = []
    private var commandLaunchValues: [[String]] = []
    private var streamContinuations: [AsyncStream<AdapterEvent>.Continuation] = []
    private var commandContinuations: [AsyncStream<Int32>.Continuation] = []
    private var streamHandles: [FakeAdapterHandle] = []
    private var commandHandles: [FakeAdapterHandle] = []
    private var streamFailuresRemaining = 0
    private var commandFailuresRemaining = 0

    var streamArguments: [[String]] {
        lock.withLock { streamLaunchValues }
    }

    var commandArguments: [[String]] {
        lock.withLock { commandLaunchValues }
    }

    var latestStreamHandle: FakeAdapterHandle? {
        lock.withLock { streamHandles.last }
    }

    var latestCommandHandle: FakeAdapterHandle? {
        lock.withLock { commandHandles.last }
    }

    func failNextStreamLaunches(_ count: Int) {
        lock.withLock { streamFailuresRemaining = count }
    }

    func failNextCommandLaunches(_ count: Int) {
        lock.withLock { commandFailuresRemaining = count }
    }

    func launchStream(arguments: [String]) throws -> AdapterStreamSession {
        let shouldFail = lock.withLock { () -> Bool in
            streamLaunchValues.append(arguments)
            guard streamFailuresRemaining > 0 else { return false }
            streamFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw TestAdapterLaunchError.forced }

        let (events, continuation) = AsyncStream.makeStream(of: AdapterEvent.self)
        let handle = FakeAdapterHandle()
        lock.withLock {
            streamContinuations.append(continuation)
            streamHandles.append(handle)
        }
        return AdapterStreamSession(handle: handle, events: events)
    }

    func launchCommand(arguments: [String]) throws -> AdapterCommandSession {
        let shouldFail = lock.withLock { () -> Bool in
            commandLaunchValues.append(arguments)
            guard commandFailuresRemaining > 0 else { return false }
            commandFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw TestAdapterLaunchError.forced }

        let (statuses, continuation) = AsyncStream.makeStream(of: Int32.self)
        let handle = FakeAdapterHandle()
        lock.withLock {
            commandContinuations.append(continuation)
            commandHandles.append(handle)
        }
        return AdapterCommandSession(handle: handle, statuses: statuses)
    }

    func emitStream(_ event: AdapterEvent) {
        let pair = lock.withLock { (streamContinuations.last, streamHandles.last) }
        guard let continuation = pair.0 else { return }
        continuation.yield(event)
        if case .exited = event {
            pair.1?.recordExit()
            continuation.finish()
        }
    }

    func finishCommand(status: Int32) {
        let pair = lock.withLock { (commandContinuations.last, commandHandles.last) }
        pair.1?.recordExit()
        pair.0?.yield(status)
        pair.0?.finish()
    }
}

actor FakeAppleScriptExecutor: AppleScriptExecuting {
    private var results: [AppleScriptExecutionResult]
    private var sourceValues: [String] = []

    init(results: [AppleScriptExecutionResult]) {
        self.results = results
    }

    func execute(_ source: String) -> AppleScriptExecutionResult {
        sourceValues.append(source)
        guard !results.isEmpty else { return .targetUnavailable }
        return results.removeFirst()
    }

    func sources() -> [String] {
        sourceValues
    }
}

actor TestSleepRecorder {
    private var values: [Duration] = []

    func sleep(for duration: Duration) {
        values.append(duration)
    }

    func durations() -> [Duration] {
        values
    }
}

@MainActor
final class MediaCallbackRecorder {
    var changes = 0
    var commands: [MediaTransportCommand] = []
    var interactions = 0
    var diagnostics: [MediaDiagnostic] = []
}

@MainActor
func settleMediaTasks() async throws {
    for _ in 0 ..< 30 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(5))
}

func mediaAdapterLine(
    title: String,
    playing: Bool,
    bundleIdentifier: String = "com.example.player"
) -> String {
    """
    {"type":"data","diff":false,"payload":{"bundleIdentifier":"\(bundleIdentifier)",\
    "playing":\(playing),"title":"\(title)","artist":"Kavinsky","album":"OutRun"}}
    """
}

func mediaTrack(
    _ title: String,
    playing: Bool,
    bundleIdentifier: String = "com.example.player"
) -> MediaNowPlaying {
    MediaNowPlaying(
        title: title,
        artist: "",
        album: "",
        appName: "Test Player",
        bundleIdentifier: bundleIdentifier,
        isPlaying: playing
    )
}
