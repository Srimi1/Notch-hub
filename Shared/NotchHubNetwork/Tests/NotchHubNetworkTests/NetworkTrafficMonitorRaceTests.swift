import Darwin
import Foundation
import Testing
@testable import NotchHubNetwork

private enum ObsoleteCounterCompletion {
    case value
    case failure
}

@MainActor
@Suite("Network traffic monitor path races", .timeLimit(.minutes(1)))
struct NetworkTrafficMonitorRaceTests {
    @Test("An unsatisfied path clears traffic, stops reads, and recovers from a baseline")
    func offlineRecovery() async throws {
        var harness = MonitorHarness()
        try await harness.start()
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 0,
            sentBytes: 0
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 1_250_000,
            sentBytes: 250_000
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }

        harness.paths.send(NetworkPathSnapshot(
            status: .unsatisfied,
            interfaces: [],
            unsatisfiedReason: "No network connection",
            generation: 2
        ))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .unavailable(message: "No network connection")
        }
        #expect(harness.recorder.latest?.downloadMbps == 0)
        #expect(harness.recorder.latest?.uploadMbps == 0)
        let offlineReadCount = harness.counters.readCount
        harness.clock.advance(by: .seconds(10))
        await Task.yield()
        #expect(harness.counters.readCount == offlineReadCount)

        harness.paths.send(satisfiedPath(generation: 3))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .measuring
        }
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 900_000_000,
            sentBytes: 90_000_000
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 901_250_000,
            sentBytes: 90_250_000
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }
        #expect(harness.recorder.latest?.downloadMbps == 10)
        #expect(harness.recorder.latest?.uploadMbps == 2)
        await harness.stop()
    }

    @Test("A result from a superseded same-index binding is ignored")
    func obsoleteCounterResult() async throws {
        try await verifyObsoleteRead(.value)
    }

    @Test("An error from a superseded same-index binding is ignored")
    func obsoleteCounterError() async throws {
        try await verifyObsoleteRead(.failure)
    }

    private func verifyObsoleteRead(_ completion: ObsoleteCounterCompletion) async throws {
        var harness = MonitorHarness()
        try await harness.start()
        let suspension = TestCounterSuspension()
        harness.counters.set(.suspended(suspension))
        harness.clock.advance(by: .seconds(1))
        try await eventually { [counters = harness.counters, suspension] in
            counters.readCount == 1 && suspension.isWaiting
        }

        harness.paths.send(NetworkPathSnapshot(
            status: .unsatisfied,
            interfaces: [],
            unsatisfiedReason: "No network connection",
            generation: 2
        ))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .unavailable(message: "No network connection")
        }
        harness.paths.send(satisfiedPath(name: "en0", index: 11, generation: 3))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .measuring && recorder.latest?.interfaceName == "en0"
        }

        switch completion {
        case .value:
            suspension.resume(returning: NetworkInterfaceCounters(
                receivedBytes: 8_000_000_000,
                sentBytes: 8_000_000_000
            ))
        case .failure:
            suspension.resume(throwing: .systemCall(operation: "obsolete read", code: EIO))
        }
        try await eventually { [clock = harness.clock] in
            clock.hasPendingSleep(for: .seconds(1))
        }
        #expect(harness.recorder.latest?.state == .measuring)
        #expect(harness.recorder.latest?.sourceError == nil)

        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 900_000_000,
            sentBytes: 90_000_000
        )))
        try await harness.tick(.counters(NetworkInterfaceCounters(
            receivedBytes: 901_250_000,
            sentBytes: 90_250_000
        )))
        try await eventually { [recorder = harness.recorder] in
            recorder.latest?.state == .live
        }
        #expect(harness.recorder.latest?.downloadMbps == 10)
        #expect(harness.recorder.latest?.uploadMbps == 2)
        await harness.stop()
    }
}
