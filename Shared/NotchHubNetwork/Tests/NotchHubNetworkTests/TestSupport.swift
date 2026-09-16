import Foundation
import os
@testable import NotchHubNetwork

enum NetworkTestError: Error {
    case timedOut
}

func eventually(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NetworkTestError.timedOut }
        try await Task.sleep(for: .milliseconds(2))
    }
}

func eventuallyAsync(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw NetworkTestError.timedOut }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
func eventuallyOnMainActor(
    timeout: Duration = .seconds(2),
    _ predicate: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NetworkTestError.timedOut }
        try await Task.sleep(for: .milliseconds(2))
    }
}

final class TestNetworkClock: NetworkTrafficTimeSource, Sendable {
    private final class Sleeper: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, any Error>?
            var isFinished = false
            var isCancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var isPending: Bool {
            state.withLock { !$0.isFinished }
        }

        func install(_ continuation: CheckedContinuation<Void, any Error>) {
            let alreadyCancelled = state.withLock {
                if $0.isCancelled { return true }
                $0.continuation = continuation
                return false
            }
            if alreadyCancelled {
                continuation.resume(throwing: CancellationError())
            }
        }

        func finish(cancelled: Bool) {
            let continuation = state.withLock {
                guard !$0.isFinished else {
                    return nil as CheckedContinuation<Void, any Error>?
                }
                $0.isFinished = true
                $0.isCancelled = cancelled
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }
            if cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume()
            }
        }
    }

    private struct ScheduledSleep: Sendable {
        let deadline: Duration
        let duration: Duration
        let sleeper: Sleeper
    }

    private struct State {
        var offset = Duration.zero
        var sleeps: [ScheduledSleep] = []
    }

    private let origin = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())

    func now() async -> ContinuousClock.Instant {
        origin.advanced(by: state.withLock { $0.offset })
    }

    func sleep(for duration: Duration) async throws {
        let sleeper = Sleeper()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeper.install(continuation)
                state.withLock {
                    $0.sleeps.append(ScheduledSleep(
                        deadline: $0.offset + duration,
                        duration: duration,
                        sleeper: sleeper
                    ))
                }
            }
        } onCancel: {
            sleeper.finish(cancelled: true)
        }
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state -> [Sleeper] in
            state.offset += duration
            let due = state.sleeps
                .filter { $0.deadline <= state.offset }
                .map(\.sleeper)
            state.sleeps.removeAll { $0.deadline <= state.offset }
            return due
        }
        for sleeper in ready {
            sleeper.finish(cancelled: false)
        }
    }

    func hasPendingSleep(for duration: Duration) -> Bool {
        state.withLock { state in
            state.sleeps.contains { $0.duration == duration && $0.sleeper.isPending }
        }
    }

    func pendingSleepCount(for duration: Duration) -> Int {
        state.withLock { state in
            state.sleeps.count { $0.duration == duration && $0.sleeper.isPending }
        }
    }
}

final class TestCounterSuspension: Sendable {
    private struct State {
        var continuation: CheckedContinuation<NetworkInterfaceCounters?, any Error>?
        var isFinished = false
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool {
        state.withLock { $0.continuation != nil && !$0.isFinished }
    }

    func wait() async throws -> NetworkInterfaceCounters? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock {
                    if $0.isCancelled { return true }
                    $0.continuation = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func resume(returning counters: NetworkInterfaceCounters?) {
        takeContinuation()?.resume(returning: counters)
    }

    func resume(throwing error: NetworkTrafficSourceError) {
        takeContinuation()?.resume(throwing: error)
    }

    private func cancel() {
        let continuation = state.withLock {
            guard !$0.isFinished else {
                return nil as CheckedContinuation<NetworkInterfaceCounters?, any Error>?
            }
            $0.isFinished = true
            $0.isCancelled = true
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func takeContinuation() -> CheckedContinuation<NetworkInterfaceCounters?, any Error>? {
        state.withLock {
            guard !$0.isFinished else { return nil }
            $0.isFinished = true
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
    }
}

final class TestCounterSource: NetworkCounterSource, Sendable {
    enum Response: Sendable {
        case counters(NetworkInterfaceCounters?)
        case failure(NetworkTrafficSourceError)
        case suspended(TestCounterSuspension)
    }

    private struct State {
        var response: Response = .counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        ))
        var readIndices: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var readCount: Int { state.withLock { $0.readIndices.count } }
    var lastIndex: Int? { state.withLock { $0.readIndices.last } }

    func set(_ response: Response) {
        state.withLock { $0.response = response }
    }

    func counters(forInterfaceIndex index: Int) async throws -> NetworkInterfaceCounters? {
        let response = state.withLock {
            $0.readIndices.append(index)
            return $0.response
        }
        switch response {
        case let .counters(counters):
            return counters
        case let .failure(error):
            throw error
        case let .suspended(suspension):
            return try await suspension.wait()
        }
    }
}

final class TestPathSource: NetworkPathSource, Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<NetworkPathSnapshot>.Continuation] = [:]
        var subscriptionCount = 0
        var cancellationCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var subscriptionCount: Int { state.withLock { $0.subscriptionCount } }
    var cancellationCount: Int { state.withLock { $0.cancellationCount } }

    func snapshots() async -> AsyncStream<NetworkPathSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream.makeStream(
            of: NetworkPathSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(identifier)
        }
        state.withLock {
            $0.subscriptionCount += 1
            $0.continuations[identifier] = pair.continuation
        }
        return pair.stream
    }

    func send(_ snapshot: NetworkPathSnapshot) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    private func remove(_ identifier: UUID) {
        state.withLock {
            if $0.continuations.removeValue(forKey: identifier) != nil {
                $0.cancellationCount += 1
            }
        }
    }
}

@MainActor
final class TestLifecycleSource: NetworkTrafficLifecycleSource {
    private var continuations: [UUID: AsyncStream<NetworkTrafficLifecycleEvent>.Continuation] = [:]

    var subscriptionCount: Int { continuations.count }

    func events() -> AsyncStream<NetworkTrafficLifecycleEvent> {
        let identifier = UUID()
        let pair = AsyncStream.makeStream(
            of: NetworkTrafficLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: identifier)
            }
        }
        return pair.stream
    }

    func send(_ event: NetworkTrafficLifecycleEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

final class TestSnapshotRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [NetworkTrafficSnapshot]())

    var values: [NetworkTrafficSnapshot] { storage.withLock { $0 } }
    var latest: NetworkTrafficSnapshot? { storage.withLock { $0.last } }

    func append(_ snapshot: NetworkTrafficSnapshot) {
        storage.withLock { $0.append(snapshot) }
    }
}

func satisfiedPath(
    name: String = "en0",
    index: Int = 11,
    kind: NetworkPathSnapshot.Interface.Kind = .wifi,
    generation: Int = 1
) -> NetworkPathSnapshot {
    NetworkPathSnapshot(
        status: .satisfied,
        interfaces: [NetworkPathSnapshot.Interface(
            name: name,
            index: index,
            kind: kind,
            isUsedByPath: true
        )],
        generation: generation
    )
}

actor TestTrafficMonitor: NetworkTrafficMonitoring {
    private var continuations: [UUID: AsyncStream<NetworkTrafficSnapshot>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false
    private var latestSnapshot = NetworkTrafficSnapshot.paused

    var subscriptionCount: Int { continuations.count }

    func updates() async -> AsyncStream<NetworkTrafficSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream.makeStream(
            of: NetworkTrafficSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.yield(latestSnapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.remove(identifier)
            }
        }
        return pair.stream
    }

    func start() async {
        guard !isActive else { return }
        isActive = true
        startCount += 1
        emit(.measuring)
    }

    func stop() async {
        guard isActive else { return }
        isActive = false
        stopCount += 1
        emit(.paused)
    }

    func emit(_ snapshot: NetworkTrafficSnapshot) {
        latestSnapshot = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func remove(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
