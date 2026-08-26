import Foundation
import Testing
@testable import NotchHub

// Shared test doubles for the media stack. They live here rather than beside one
// suite because both the source tests and the startup tests drive the adapter
// without spawning anything.

/// Unchecked: these tests run entirely on the main actor, and the fakes are only
/// touched from there.
final class Counter: @unchecked Sendable {
    var value = 0
}

final class Schedule: @unchecked Sendable {
    var delays: [TimeInterval] = []
}

/// A hand-wound clock, so a test can say how long an adapter run lasted
/// without waiting for it.
final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

final class FakeLauncherState: @unchecked Sendable {
    var launches: [[String]] = []
    var detached: [[String]] = []
    var continuations: [AsyncStream<AdapterEvent>.Continuation] = []
    var handles: [FakeHandle] = []
    var failNextLaunch = false
}

struct LaunchFailed: Error {}

final class FakeLauncher: AdapterLaunching, @unchecked Sendable {
    let state = FakeLauncherState()

    func launch(arguments: [String]) throws -> AdapterSession {
        state.launches.append(arguments)
        if state.failNextLaunch {
            state.failNextLaunch = false
            throw LaunchFailed()
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AdapterEvent.self)
        state.continuations.append(continuation)
        let handle = FakeHandle()
        state.handles.append(handle)
        return AdapterSession(handle: handle, events: stream)
    }

    func runDetached(arguments: [String]) {
        state.detached.append(arguments)
    }

    /// Feed the most recently launched process. `.exited` finishes its stream,
    /// exactly as the real launcher does.
    func emit(_ event: AdapterEvent) {
        guard let continuation = state.continuations.last else { return }
        continuation.yield(event)
        if case .exited = event { continuation.finish() }
    }
}

final class FakeHandle: AdapterProcessHandle, @unchecked Sendable {
    private(set) var isRunning = true
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}
