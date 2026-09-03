import Foundation
import Testing
@testable import NotchHubSafeFeatures

@MainActor
@Suite("Safe dashboard")
struct DashboardModelTests {
    @Test("Process-independent snapshots render real bounded state")
    func suppliedSnapshotIsPublished() {
        let date = Date(timeIntervalSince1970: 1000)
        let expected = snapshot(at: date)
        let provider = DashboardProviderStub(result: .success(expected))

        let model = DashboardModel(provider: provider, now: { date })

        #expect(model.snapshot == expected)
        #expect(model.lastError == nil)
        #expect(model.uptimeComponents.days == 1)
        #expect(model.uptimeComponents.hours == 1)
        #expect(model.uptimeComponents.minutes == 1)
    }

    @Test("A failed refresh preserves the last trustworthy snapshot")
    func failurePreservesSnapshot() {
        let date = Date(timeIntervalSince1970: 1000)
        let expected = snapshot(at: date)
        let provider = DashboardProviderStub(result: .success(expected))
        let model = DashboardModel(provider: provider, now: { date })
        provider.result = .failure(.unavailable)

        model.refresh()

        #expect(model.snapshot == expected)
        #expect(model.lastError == "System summary is temporarily unavailable.")
        #expect(!model.isRefreshing)
    }

    @Test("Untrusted negative system values are clamped")
    func invalidValuesAreClamped() {
        let value = DashboardSnapshot(
            sampledAt: .distantPast,
            systemUptime: -20,
            activeProcessorCount: -4,
            physicalMemoryBytes: 0,
            thermalState: .unavailable,
            isLowPowerModeEnabled: false
        )

        #expect(value.systemUptime == 0)
        #expect(value.activeProcessorCount == 0)
    }

    private func snapshot(at date: Date) -> DashboardSnapshot {
        DashboardSnapshot(
            sampledAt: date,
            systemUptime: 90060,
            activeProcessorCount: 8,
            physicalMemoryBytes: 16_000_000_000,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        )
    }
}

@MainActor
private final class DashboardProviderStub: DashboardSnapshotProviding {
    enum Failure: Error {
        case unavailable
    }

    var result: Result<DashboardSnapshot, Failure>

    init(result: Result<DashboardSnapshot, Failure>) {
        self.result = result
    }

    func snapshot(at date: Date) throws -> DashboardSnapshot {
        try result.get()
    }
}
