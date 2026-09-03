import Foundation
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

@Suite("Direct agent runtime")
struct RuntimeDirectAgentRuntimeTests {
    @Test("Startup loads encrypted cache, refreshes live providers, and persists last-good values")
    func startupAndLiveRefresh() async throws {
        let cachedClaude = try runtimeSnapshot(provider: .claude, usedPercent: 30, capturedAt: 1000)
        let liveCodex = try runtimeSnapshot(provider: .codex, usedPercent: 45, capturedAt: 2000)
        let codexAdapter = RuntimeTrackedUsageAdapter(provider: .codex, result: .success(liveCodex))
        let claudeAdapter = RuntimeTrackedUsageAdapter(
            provider: .claude,
            result: .failure(.adapterUnavailable(provider: .claude))
        )
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([.claude: cachedClaude]))
        let runtime = makeRuntime(
            store: store,
            adapters: [.codex: codexAdapter, .claude: claudeAdapter],
            now: 2001
        )

        let state = await runtime.start()

        let codexState = try #require(state.state(for: .codex))
        #expect(codexState.connectionState == .connected(lastRefresh: liveCodex.capturedAt))
        #expect(codexState.usageSnapshot == liveCodex)
        #expect(codexState.snapshotSource == .liveProvider)

        let claudeState = try #require(state.state(for: .claude))
        #expect(claudeState.usageSnapshot == cachedClaude)
        #expect(claudeState.snapshotSource == .encryptedCache)
        #expect(
            claudeState.connectionState
                == .stale(
                    lastSuccessfulRefresh: cachedClaude.capturedAt,
                    reason: .adapterUnavailable(provider: .claude)
                )
        )

        let saved = try #require(await store.saves().last)
        #expect(saved == [.codex: liveCodex, .claude: cachedClaude])
    }

    @Test("Offline refresh retains cache and never persists a failed response")
    func offlineRetention() async throws {
        let cached = try runtimeSnapshot(provider: .codex, usedPercent: 20, capturedAt: 1000)
        let adapter = RuntimeTrackedUsageAdapter(
            provider: .codex,
            result: .failure(.offline(provider: .codex))
        )
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([.codex: cached]))
        let telemetry = RuntimeTelemetryFixture()
        let runtime = makeRuntime(
            store: store,
            adapters: [.codex: adapter],
            telemetry: telemetry,
            now: 1001
        )

        _ = await runtime.start(refreshLiveData: false)
        let state = await runtime.refresh(.codex)

        #expect(state.usageSnapshot == cached)
        #expect(
            state.connectionState
                == .stale(lastSuccessfulRefresh: cached.capturedAt, reason: .offline(provider: .codex))
        )
        #expect(await store.saves().isEmpty)
        #expect(await telemetry.events().contains { $0.code == "offline-refresh" })
    }

    @Test("Missing CLIs do not create adapters or child operations")
    func missingCLI() async {
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let factory = RuntimeAdapterFactoryFixture(adapters: [:])
        let telemetry = RuntimeTelemetryFixture()
        let runtime = DirectAgentRuntime(
            discovery: RuntimeDiscoveryFixture(outcomes: [:]),
            snapshotStore: store,
            adapterFactory: factory,
            telemetry: telemetry
        )

        let state = await runtime.start()

        #expect(state.state(for: .codex)?.connectionState == .notDetected)
        #expect(state.state(for: .claude)?.connectionState == .notDetected)
        #expect(await factory.callCount(for: .codex) == 0)
        #expect(await factory.callCount(for: .claude) == 0)
        #expect(await telemetry.events().filter { $0.code == "cli-not-found-discovery" }.count == 2)
    }

    @Test("Concurrent refreshes coalesce and release the adapter before returning")
    func refreshCoalescingAndCleanup() async throws {
        let live = try runtimeSnapshot(provider: .codex, usedPercent: 55, capturedAt: 2000)
        let adapter = RuntimeTrackedUsageAdapter(
            provider: .codex,
            result: .success(live),
            delay: .milliseconds(75)
        )
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let factory = RuntimeAdapterFactoryFixture(adapters: [.codex: adapter])
        let runtime = makeRuntime(store: store, factory: factory, now: 2001)
        _ = await runtime.start(refreshLiveData: false)

        async let first = runtime.refresh(.codex)
        async let second = runtime.refresh(.codex)
        let values = await [first, second]

        #expect(values[0] == values[1])
        #expect(await factory.callCount(for: .codex) == 1)
        let metrics = await adapter.metrics()
        #expect(metrics.calls == 1)
        #expect(metrics.active == 0)
        #expect(metrics.maximumActive == 1)
        #expect(await store.saves().count == 1)
    }

    @Test("Launch refreshes providers in parallel instead of stacking provider deadlines")
    func parallelLaunchRefresh() async throws {
        let codex = try runtimeSnapshot(provider: .codex, usedPercent: 25, capturedAt: 2000)
        let claude = try runtimeSnapshot(provider: .claude, usedPercent: 35, capturedAt: 2000)
        let barrier = RuntimeFetchBarrier()
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let runtime = makeRuntime(
            store: store,
            adapters: [
                .codex: RuntimeBarrierUsageAdapter(snapshot: codex, barrier: barrier),
                .claude: RuntimeBarrierUsageAdapter(snapshot: claude, barrier: barrier),
            ],
            now: 2001
        )

        let startTask = Task { await runtime.start() }
        let enteredProviders = try await waitForRuntimeFetches(barrier, expectedCount: 2)
        #expect(enteredProviders == Set([.codex, .claude]))
        await barrier.releaseAll()
        let state = await startTask.value

        #expect(state.state(for: .codex)?.usageSnapshot == codex)
        #expect(state.state(for: .claude)?.usageSnapshot == claude)
    }

    @Test("Malformed cached state is reported without logging the underlying error")
    func cacheFailureIsRedacted() async {
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .failed)
        let telemetry = RuntimeTelemetryFixture()
        let runtime = DirectAgentRuntime(
            discovery: RuntimeDiscoveryFixture(outcomes: [:]),
            snapshotStore: store,
            adapterFactory: RuntimeAdapterFactoryFixture(adapters: [:]),
            telemetry: telemetry
        )

        let state = await runtime.start(refreshLiveData: false)

        #expect(state.persistenceState == .failed)
        let events = await telemetry.events()
        #expect(events.contains { $0.code == "cache-load-failed" })
        #expect(!events.map(\.summary).joined().contains("fixture"))
    }

    @Test("Cross-provider snapshots fail validation and are never saved")
    func crossProviderSnapshot() async throws {
        let wrong = try runtimeSnapshot(provider: .claude, usedPercent: 10, capturedAt: 2000)
        let adapter = RuntimeTrackedUsageAdapter(provider: .codex, result: .success(wrong))
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let telemetry = RuntimeTelemetryFixture()
        let runtime = makeRuntime(
            store: store,
            adapters: [.codex: adapter],
            telemetry: telemetry,
            now: 2001
        )

        _ = await runtime.start(refreshLiveData: false)
        let state = await runtime.refresh(.codex)

        #expect(
            state.connectionState
                == .failed(.invalidPayload(provider: .codex, field: "live snapshot provider"))
        )
        #expect(state.usageSnapshot == nil)
        #expect(await store.saves().isEmpty)
        #expect(await telemetry.events().contains { $0.code == "invalid-payload-refresh" })
    }

    @Test("Cache save failure does not discard a successful live result")
    func cacheSaveFailure() async throws {
        let live = try runtimeSnapshot(provider: .codex, usedPercent: 60, capturedAt: 2000)
        let adapter = RuntimeTrackedUsageAdapter(provider: .codex, result: .success(live))
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]), saveFails: true)
        let telemetry = RuntimeTelemetryFixture()
        let runtime = makeRuntime(
            store: store,
            adapters: [.codex: adapter],
            telemetry: telemetry,
            now: 2001
        )

        _ = await runtime.start(refreshLiveData: false)
        let providerState = await runtime.refresh(.codex)
        let runtimeState = await runtime.runtimeSnapshot()

        #expect(providerState.usageSnapshot == live)
        #expect(providerState.connectionState == .connected(lastRefresh: live.capturedAt))
        #expect(runtimeState.persistenceState == .failed)
        #expect(await telemetry.events().contains { $0.code == "cache-save-failed" })
    }
}

extension RuntimeDirectAgentRuntimeTests {
    @Test("Claude status-line ingestion refreshes through the same bounded runtime path")
    func claudeStatusLine() async throws {
        let live = try runtimeSnapshot(provider: .claude, usedPercent: 35, capturedAt: 2000)
        let adapter = RuntimeTrackedUsageAdapter(provider: .claude, result: .success(live))
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let factory = RuntimeAdapterFactoryFixture(adapters: [.claude: adapter])
        let runtime = makeRuntime(store: store, factory: factory, now: 2001)
        _ = await runtime.start(refreshLiveData: false)

        let state = await runtime.ingestClaudeStatusLine(
            Data(#"{"rate_limits":{}}"#.utf8),
            capturedAt: live.capturedAt
        )

        #expect(state.usageSnapshot == live)
        #expect(await factory.ingestedPayloadCount() == 1)
        #expect(await factory.callCount(for: .claude) == 1)
    }

    @Test("Sanitized bridge status-line data becomes an encrypted last-good snapshot")
    func bridgeClaudeStatusLine() async throws {
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([:]))
        let runtime = makeRuntime(store: store, adapters: [:], now: 2001)
        _ = await runtime.start(refreshLiveData: false)
        let capturedAt = Date(timeIntervalSince1970: 2000)
        let event = try BridgeStatusLineEvent(
            provider: .claude,
            sessionID: "session-1",
            rateLimits: [
                try BridgeRateLimitWindow(
                    id: .fiveHour,
                    usedPercent: 35,
                    resetsAt: capturedAt.addingTimeInterval(300)
                ),
                try BridgeRateLimitWindow(
                    id: .sevenDay,
                    usedPercent: 65,
                    resetsAt: capturedAt.addingTimeInterval(3600)
                ),
            ],
            capturedAt: capturedAt
        )

        let state = await runtime.ingestClaudeStatusLine(event)

        #expect(state.connectionState == .connected(lastRefresh: capturedAt))
        #expect(state.snapshotSource == .liveProvider)
        #expect(state.usageSnapshot?.windows.map(\.id) == ["fiveHour", "sevenDay"])
        #expect(state.usageSnapshot?.highestUsedPercent == 65)
        #expect(await store.saves().last?[.claude] == state.usageSnapshot)
    }

    @Test("Cached state publishes before provider discovery")
    func cacheFirstStartup() async throws {
        let cached = try runtimeSnapshot(provider: .codex, usedPercent: 28, capturedAt: 1000)
        let store = RuntimeSnapshotStoreFixture(loadOutcome: .snapshots([.codex: cached]))
        let discovery = RuntimeDiscoveryFixture(
            outcomes: [
                .codex: .found(runtimeExecutable(.codex)),
                .claude: .found(runtimeExecutable(.claude)),
            ]
        )
        let runtime = DirectAgentRuntime(
            discovery: discovery,
            snapshotStore: store,
            adapterFactory: RuntimeAdapterFactoryFixture(adapters: [:]),
            telemetry: RuntimeTelemetryFixture(),
            now: { Date(timeIntervalSince1970: 1001) }
        )

        let state = await runtime.loadCachedState()

        #expect(state.state(for: .codex)?.usageSnapshot == cached)
        #expect(state.state(for: .codex)?.executableSource == nil)
        #expect(state.state(for: .claude)?.connectionState == .notDetected)
    }

    private func makeRuntime(
        store: RuntimeSnapshotStoreFixture,
        adapters: [ProviderID: any UsageProviderAdapter],
        telemetry: RuntimeTelemetryFixture = RuntimeTelemetryFixture(),
        now: TimeInterval
    ) -> DirectAgentRuntime {
        makeRuntime(
            store: store,
            factory: RuntimeAdapterFactoryFixture(adapters: adapters),
            telemetry: telemetry,
            now: now
        )
    }

    private func makeRuntime(
        store: RuntimeSnapshotStoreFixture,
        factory: RuntimeAdapterFactoryFixture,
        telemetry: RuntimeTelemetryFixture = RuntimeTelemetryFixture(),
        now: TimeInterval
    ) -> DirectAgentRuntime {
        DirectAgentRuntime(
            discovery: RuntimeDiscoveryFixture(
                outcomes: [
                    .codex: .found(runtimeExecutable(.codex)),
                    .claude: .found(runtimeExecutable(.claude)),
                ]
            ),
            snapshotStore: store,
            adapterFactory: factory,
            telemetry: telemetry,
            now: { Date(timeIntervalSince1970: now) }
        )
    }
}
