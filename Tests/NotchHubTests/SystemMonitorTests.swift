import Testing
@testable import NotchHub

/// The disk arithmetic, split out so it can be checked without a live volume —
/// the read itself now runs off the main thread.
@Suite("System monitor disk metrics")
struct SystemMonitorTests {

    private static let gib = 1_073_741_824.0

    @Test
    func zeroCapacityIsRejected() {
        #expect(SystemMonitorService.diskMetrics(total: 0, free: 0) == nil)
        #expect(SystemMonitorService.diskMetrics(total: -1, free: 0) == nil)
    }

    @Test
    func usageAndFreeGigabytesAreComputed() {
        let metrics = SystemMonitorService.diskMetrics(total: 100 * Self.gib, free: 25 * Self.gib)
        #expect(metrics != nil)
        if let metrics {
            #expect(abs(metrics.usage - 0.75) < 0.0001)
            #expect(abs(metrics.freeGB - 25) < 0.0001)
        }
    }

    /// Available-for-important-usage counts purgeable space, so it can exceed raw
    /// free space or go negative under pressure. The fraction stays in 0...1.
    @Test
    func usageIsClampedToUnitRange() {
        #expect(SystemMonitorService.diskMetrics(total: 100, free: 250)?.usage == 0)
        #expect(SystemMonitorService.diskMetrics(total: 100, free: -50)?.usage == 1)
    }
}
