import Testing
@testable import NotchHubNetwork

@MainActor
@Suite("Network traffic presentation model", .timeLimit(.minutes(1)))
struct NetworkTrafficModelTests {
    @Test("A model that was never started performs no monitoring")
    func hiddenModelDoesNoWork() async {
        let monitor = TestTrafficMonitor()
        let model = NetworkTrafficModel(monitor: monitor)
        await Task.yield()
        #expect(!model.isRunning)
        #expect(model.snapshot == .paused)
        #expect(await monitor.startCount == 0)
        #expect(await monitor.subscriptionCount == 0)
    }

    @Test("Start and stop are idempotent and forward snapshots")
    func lifecycleAndUpdates() async throws {
        let monitor = TestTrafficMonitor()
        let model = NetworkTrafficModel(monitor: monitor)
        model.start()
        model.start()
        try await eventuallyAsync {
            let startCount = await monitor.startCount
            let subscriptionCount = await monitor.subscriptionCount
            return startCount == 1 && subscriptionCount == 1
        }

        let live = NetworkTrafficSnapshot(
            downloadMbps: 12.5,
            uploadMbps: 1.25,
            interfaceName: "en0",
            state: .live
        )
        await monitor.emit(live)
        try await eventuallyOnMainActor { model.snapshot == live }
        #expect(model.downloadMbps == 12.5)
        #expect(model.uploadMbps == 1.25)
        #expect(model.interfaceName == "en0")

        model.stop()
        model.stop()
        try await eventuallyAsync { await monitor.stopCount == 1 }
        #expect(!model.isRunning)
        #expect(model.snapshot == .paused)
    }

    @Test("Rapid stop and restart keeps only the newest session")
    func rapidCycles() async throws {
        let monitor = TestTrafficMonitor()
        let model = NetworkTrafficModel(monitor: monitor)
        model.start()
        try await eventuallyAsync { await monitor.startCount == 1 }
        let oldSession = NetworkTrafficSnapshot(
            downloadMbps: 999,
            uploadMbps: 999,
            interfaceName: "en0",
            state: .live
        )
        await monitor.emit(oldSession)
        try await eventuallyOnMainActor { model.snapshot == oldSession }
        model.stop()
        model.start()

        try await eventuallyAsync {
            let stopCount = await monitor.stopCount
            let startCount = await monitor.startCount
            let isActive = await monitor.isActive
            let subscriptionCount = await monitor.subscriptionCount
            return stopCount == 1
                && startCount == 2
                && isActive
                && subscriptionCount == 1
        }
        #expect(model.snapshot == .measuring)
        let current = NetworkTrafficSnapshot(
            downloadMbps: 8,
            uploadMbps: 2,
            interfaceName: "en5",
            state: .live
        )
        await monitor.emit(current)
        try await eventuallyOnMainActor { model.snapshot == current }
        #expect(model.isRunning)

        model.stop()
        try await eventuallyAsync { await monitor.stopCount == 2 }
    }

    @Test("A stopped model ignores late data from an obsolete subscription")
    func obsoleteUpdatesAreIgnored() async throws {
        let monitor = TestTrafficMonitor()
        let model = NetworkTrafficModel(monitor: monitor)
        model.start()
        try await eventuallyAsync { await monitor.startCount == 1 }
        model.stop()
        await monitor.emit(NetworkTrafficSnapshot(
            downloadMbps: 500,
            uploadMbps: 500,
            interfaceName: "utun9",
            state: .live
        ))
        await Task.yield()
        #expect(model.snapshot == .paused)
        #expect(model.downloadMbps == 0)
    }
}
