import Testing
@testable import NotchHubNetwork

@Suite("Throughput calculator")
struct ThroughputCalculatorTests {
    private let calculator = NetworkThroughputCalculator()

    @Test("Rates use measured elapsed time")
    func irregularInterval() {
        let result = calculator.evaluate(
            previous: NetworkInterfaceCounters(receivedBytes: 0, sentBytes: 0),
            current: NetworkInterfaceCounters(receivedBytes: 1_250_000, sentBytes: 625_000),
            elapsedSeconds: 1.25
        )
        #expect(result == .rate(downloadMbps: 8, uploadMbps: 4))
    }

    @Test("Counters remain 64-bit above the UInt32 boundary")
    func largeCounters() {
        let base = UInt64(UInt32.max) + 2_000_000_000
        let result = calculator.evaluate(
            previous: NetworkInterfaceCounters(receivedBytes: base, sentBytes: base),
            current: NetworkInterfaceCounters(
                receivedBytes: base + 1_250_000,
                sentBytes: base + 250_000
            ),
            elapsedSeconds: 1
        )
        #expect(result == .rate(downloadMbps: 10, uploadMbps: 2))
    }

    @Test("A reset rebaselines instead of underflowing")
    func counterReset() {
        let result = calculator.evaluate(
            previous: NetworkInterfaceCounters(receivedBytes: 9_000_000, sentBytes: 20),
            current: NetworkInterfaceCounters(receivedBytes: 10, sentBytes: 20),
            elapsedSeconds: 1
        )
        #expect(result == .rebaseline(reason: .counterWentBackwards))
    }

    @Test("Long gaps and implausible rates are discarded")
    func untrustworthyDeltas() {
        let zero = NetworkInterfaceCounters(receivedBytes: 0, sentBytes: 0)
        #expect(calculator.evaluate(
            previous: zero,
            current: NetworkInterfaceCounters(receivedBytes: 1_250_000, sentBytes: 0),
            elapsedSeconds: 3.1,
            maximumGapSeconds: 3
        ) == .rebaseline(reason: .staleGap))
        #expect(calculator.evaluate(
            previous: zero,
            current: NetworkInterfaceCounters(receivedBytes: 50_000_000_000, sentBytes: 0),
            elapsedSeconds: 1
        ) == .rebaseline(reason: .implausibleRate))
    }

    @Test("Sub-threshold intervals keep the existing baseline")
    func tooSoon() {
        let result = calculator.evaluate(
            previous: NetworkInterfaceCounters(receivedBytes: 0, sentBytes: 0),
            current: NetworkInterfaceCounters(receivedBytes: 10, sentBytes: 10),
            elapsedSeconds: 0.05
        )
        #expect(result == .tooSoon)
    }
}
