import Foundation
@testable import NotchHubCore

enum RuntimeFixtureFailure: Error, Sendable {
    case discovery
    case storage
    case statusLine
}

enum RuntimeDiscoveryOutcome: Sendable {
    case found(DiscoveredExecutable)
    case missing
    case failed
}

struct RuntimeDiscoveryFixture: DirectAgentExecutableDiscovering {
    let outcomes: [ProviderID: RuntimeDiscoveryOutcome]

    func discover(_ provider: ProviderID) throws -> DiscoveredExecutable? {
        switch outcomes[provider] ?? .missing {
        case let .found(executable): executable
        case .missing: nil
        case .failed: throw RuntimeFixtureFailure.discovery
        }
    }
}

enum RuntimeStoreLoadOutcome: Sendable {
    case snapshots([ProviderID: UsageSnapshot])
    case failed
}

actor RuntimeSnapshotStoreFixture: DirectAgentSnapshotStoring {
    private let loadOutcome: RuntimeStoreLoadOutcome
    private let saveFails: Bool
    private var savedValues: [[ProviderID: UsageSnapshot]] = []

    init(
        loadOutcome: RuntimeStoreLoadOutcome,
        saveFails: Bool = false
    ) {
        self.loadOutcome = loadOutcome
        self.saveFails = saveFails
    }

    func load() async throws -> [ProviderID: UsageSnapshot] {
        switch loadOutcome {
        case let .snapshots(snapshots): snapshots
        case .failed: throw RuntimeFixtureFailure.storage
        }
    }

    func save(_ snapshots: [ProviderID: UsageSnapshot]) async throws {
        guard !saveFails else {
            throw RuntimeFixtureFailure.storage
        }
        savedValues.append(snapshots)
    }

    func saves() -> [[ProviderID: UsageSnapshot]] {
        savedValues
    }
}

actor RuntimeTelemetryFixture: DirectAgentRuntimeTelemetry {
    private var recordedEvents: [DirectAgentRuntimeTelemetryEvent] = []

    func record(_ event: DirectAgentRuntimeTelemetryEvent) async {
        recordedEvents.append(event)
    }

    func events() -> [DirectAgentRuntimeTelemetryEvent] {
        recordedEvents
    }
}

actor RuntimeAdapterFactoryFixture: DirectAgentAdapterFactory {
    private let adapters: [ProviderID: any UsageProviderAdapter]
    private let statusLineFails: Bool
    private var calls: [ProviderID: Int] = [:]
    private var statusLinePayloadCount = 0

    init(
        adapters: [ProviderID: any UsageProviderAdapter],
        statusLineFails: Bool = false
    ) {
        self.adapters = adapters
        self.statusLineFails = statusLineFails
    }

    func makeAdapter(
        for provider: ProviderID,
        executable: DiscoveredExecutable,
        timeout: TimeInterval
    ) async throws -> any UsageProviderAdapter {
        calls[provider, default: 0] += 1
        guard executable.provider == provider,
              (1 ... 15).contains(timeout),
              let adapter = adapters[provider]
        else {
            throw ProviderError.adapterUnavailable(provider: provider)
        }
        return adapter
    }

    func ingestClaudeStatusLine(_ data: Data, capturedAt: Date) async throws {
        guard !statusLineFails else {
            throw RuntimeFixtureFailure.statusLine
        }
        guard !data.isEmpty, capturedAt.timeIntervalSince1970 > 0 else {
            throw RuntimeFixtureFailure.statusLine
        }
        statusLinePayloadCount += 1
    }

    func callCount(for provider: ProviderID) -> Int {
        calls[provider, default: 0]
    }

    func ingestedPayloadCount() -> Int {
        statusLinePayloadCount
    }
}

actor RuntimeTrackedUsageAdapter: UsageProviderAdapter {
    nonisolated let provider: ProviderID

    private let result: Result<UsageSnapshot, ProviderError>
    private let delay: Duration
    private var calls = 0
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    init(
        provider: ProviderID,
        result: Result<UsageSnapshot, ProviderError>,
        delay: Duration = .zero
    ) {
        self.provider = provider
        self.result = result
        self.delay = delay
    }

    func fetchUsage() async throws -> UsageSnapshot {
        calls += 1
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        defer { activeOperations -= 1 }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }

    func metrics() -> RuntimeAdapterMetrics {
        RuntimeAdapterMetrics(
            calls: calls,
            active: activeOperations,
            maximumActive: maximumActiveOperations
        )
    }
}

struct RuntimeAdapterMetrics: Sendable {
    let calls: Int
    let active: Int
    let maximumActive: Int
}

func runtimeExecutable(_ provider: ProviderID) -> DiscoveredExecutable {
    DiscoveredExecutable(
        provider: provider,
        url: URL(fileURLWithPath: "/fixture/bin/\(provider.executableName)"),
        source: .path
    )
}

func runtimeSnapshot(
    provider: ProviderID,
    usedPercent: Double,
    capturedAt: TimeInterval
) throws -> UsageSnapshot {
    try UsageSnapshot(
        provider: provider,
        windows: [
            QuotaWindow(
                id: "\(provider.rawValue).primary",
                label: "Primary",
                usedPercent: usedPercent
            ),
        ],
        capturedAt: Date(timeIntervalSince1970: capturedAt)
    )
}
