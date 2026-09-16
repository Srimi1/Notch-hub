import Foundation
import Testing
@testable import NotchHubNetwork

@MainActor
struct MonitorHarness {
    let clock: TestNetworkClock
    let counters: TestCounterSource
    let paths: TestPathSource
    let lifecycle: TestLifecycleSource
    let recorder: TestSnapshotRecorder
    let monitor: NetworkTrafficMonitor
    private var collector: Task<Void, Never>?

    init() {
        let clock = TestNetworkClock()
        let counters = TestCounterSource()
        let paths = TestPathSource()
        let lifecycle = TestLifecycleSource()
        self.clock = clock
        self.counters = counters
        self.paths = paths
        self.lifecycle = lifecycle
        recorder = TestSnapshotRecorder()
        monitor = NetworkTrafficMonitor(
            counterSource: counters,
            pathSource: paths,
            timeSource: clock,
            lifecycleSource: lifecycle,
            sampleInterval: .seconds(1),
            staleAfter: .seconds(3)
        )
    }

    mutating func start(path: NetworkPathSnapshot = satisfiedPath()) async throws {
        let stream = await monitor.updates()
        let recorder = recorder
        collector = Task {
            for await snapshot in stream {
                recorder.append(snapshot)
            }
        }
        await monitor.start()
        try await eventually { [clock, paths] in
            paths.subscriptionCount == 1 && clock.hasPendingSleep(for: .seconds(1))
        }
        paths.send(path)
        try await eventually { [recorder] in
            recorder.latest?.interfaceName == path.activeInterface?.name
        }
    }

    func tick(
        _ response: TestCounterSource.Response,
        after duration: Duration = .seconds(1)
    ) async throws {
        counters.set(response)
        let previousReadCount = counters.readCount
        clock.advance(by: duration)
        try await eventually { [clock, counters] in
            counters.readCount > previousReadCount
                && clock.hasPendingSleep(for: .seconds(1))
        }
    }

    func stop() async {
        collector?.cancel()
        await monitor.stop()
    }
}

@MainActor
@Suite("Network traffic monitor", .timeLimit(.minutes(1)))
struct NetworkTrafficMonitorTests {
    @Test("Publishes measured rates and keeps measured zero live")
    func ratesAndZero() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 100,
            sentBytes: 100
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_100,
            sentBytes: 250_100
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }
        #expect(harness.recorder.latest?.downloadMbps == 10)
        #expect(harness.recorder.latest?.uploadMbps == 2)

        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_100,
            sentBytes: 250_100
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live && recorder.latest?.downloadMbps == 0
        }
        #expect(harness.recorder.latest?.state.hasReading == true)
        await harness.stop()
    }

    @Test("Typed source failures clear rates and recover from a fresh baseline")
    func sourceFailureRecovery() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 0
        )))
        let failure = NetworkTrafficSourceError.systemCall(
            operation: "test read",
            code: EIO
        )
        try await harness.tick(.failure(failure))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.sourceError == failure
        }
        #expect(harness.recorder.latest?.downloadMbps == 0)

        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 900_000_000,
            sentBytes: 0
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .measuring
        }
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 901_250_000,
            sentBytes: 0
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
                && recorder.latest?.sourceError == nil
        }
        #expect(harness.recorder.latest?.downloadMbps == 10)
        await harness.stop()
    }

    @Test("A missing selected interface is an explicit failure")
    func missingInterfaceCounters() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(nil))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.sourceError == .interfaceDisappeared(11)
        }
        #expect(harness.recorder.latest?.state == .unavailable(
            message: "The selected network interface is unavailable"
        ))
        await harness.stop()
    }

    @Test("Replacing the interface clears the old reading and rebaselines")
    func interfaceReplacement() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 0
        )))
        harness.paths.send(satisfiedPath(name: "en5", index: 14, kind: .wiredEthernet, generation: 2))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.interfaceName == "en5" && recorder.latest?.state == .measuring
        }
        #expect(harness.recorder.latest?.downloadMbps == 0)

        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 500_000_000,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 501_250_000,
            sentBytes: 0
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }
        #expect(harness.counters.lastIndex == 14)
        #expect(harness.recorder.latest?.downloadMbps == 10)
        await harness.stop()
    }

    @Test("Sleep stops all work and wake creates a fresh path session")
    func sleepAndWake() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await eventuallyAsync { [lifecycle = harness.lifecycle] in
            await lifecycle.subscriptionCount == 1
        }
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 0
        )))

        harness.lifecycle.send(.willSleep)
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .unavailable(message: "Paused while the Mac sleeps")
        }
        let sleepingReadCount = harness.counters.readCount
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(harness.counters.readCount == sleepingReadCount)
        try await eventually { [paths = harness.paths] in paths.cancellationCount == 1 }

        harness.lifecycle.send(.didWake)
        try await eventually { [paths = harness.paths] in paths.subscriptionCount == 2 }
        harness.paths.send(satisfiedPath(
            name: "en5",
            index: 14,
            kind: .wiredEthernet,
            generation: 2
        ))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.interfaceName == "en5"
        }
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 900_000_000,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 901_250_000,
            sentBytes: 0
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }
        #expect(harness.recorder.latest?.downloadMbps == 10)
        await harness.stop()
    }

    @Test("A stalled sampler expires the last reading within three seconds")
    func staleExpiry() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 0
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }

        let suspension = TestCounterSuspension()
        harness.counters.set(.suspended(suspension))
        let readCount = harness.counters.readCount
        harness.clock.advance(by: .seconds(1))
        try await eventually { [counters = harness.counters] in
            counters.readCount > readCount
        }
        harness.clock.advance(by: .seconds(2))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .unavailable(
                message: "Waiting for a fresh network reading"
            )
        }
        #expect(harness.recorder.latest?.downloadMbps == 0)
        #expect(harness.recorder.latest?.uploadMbps == 0)
        await harness.stop()
    }

    @Test("Start and stop are idempotent and stopped monitors perform no reads")
    func lifecycleIdempotence() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        await harness.monitor.start()
        #expect(harness.paths.subscriptionCount == 1)
        #expect(harness.clock.pendingSleepCount(for: .seconds(1)) == 1)
        await harness.stop()
        let readCount = harness.counters.readCount
        harness.clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(harness.counters.readCount == readCount)
        await harness.monitor.stop()
        #expect(harness.recorder.values.filter { $0 == .paused }.count <= 1)
    }

    @Test("Late termination from an old subscriber cannot stop a replacement run")
    func lateSubscriberTerminationAfterRestart() async throws {
        let clock = TestNetworkClock()
        let counters = TestCounterSource()
        let paths = TestPathSource()
        let lifecycle = TestLifecycleSource()
        let monitor = NetworkTrafficMonitor(
            counterSource: counters,
            pathSource: paths,
            timeSource: clock,
            lifecycleSource: lifecycle
        )

        let firstStream = await monitor.updates()
        let firstCollector = Task {
            for await _ in firstStream {}
        }
        await monitor.start()
        try await eventually { [clock, paths] in
            paths.subscriptionCount == 1 && clock.hasPendingSleep(for: .seconds(1))
        }
        await monitor.stop()
        await monitor.start()
        try await eventually { [clock, paths] in
            paths.subscriptionCount == 2 && clock.hasPendingSleep(for: .seconds(1))
        }
        firstCollector.cancel()

        let recorder = TestSnapshotRecorder()
        let replacementStream = await monitor.updates()
        let replacementCollector = Task {
            for await snapshot in replacementStream {
                recorder.append(snapshot)
            }
        }
        paths.send(satisfiedPath())
        try await eventually { recorder.latest?.interfaceName == "en0" }

        counters.set(.counters(NetworkInterfaceCounters(receivedBytes: 0, sentBytes: 0)))
        let baselineReadCount = counters.readCount
        clock.advance(by: .seconds(1))
        try await eventually { [clock, counters] in
            counters.readCount > baselineReadCount
                && clock.hasPendingSleep(for: .seconds(1))
        }
        counters.set(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 250_000
        )))
        let sampleReadCount = counters.readCount
        clock.advance(by: .seconds(1))
        try await eventually { [clock, counters] in
            counters.readCount > sampleReadCount
                && clock.hasPendingSleep(for: .seconds(1))
        }
        try await eventually { recorder.latest?.state == .live }
        #expect(recorder.latest?.downloadMbps == 10)
        #expect(recorder.latest?.uploadMbps == 2)

        replacementCollector.cancel()
        await monitor.stop()
    }
}
