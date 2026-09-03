import Foundation

public actor DirectAgentRuntime {
    public typealias Clock = @Sendable () -> Date

    enum DiscoveryResult: Sendable {
        case resolved(DiscoveredExecutable?)
        case failed(ProviderError)
    }

    struct RefreshOperation: Sendable {
        let id: UInt64
        let task: Task<UsageSnapshot, any Error>
    }

    enum SaveResult: Sendable {
        case saved
        case failed
    }

    struct SaveOperation: Sendable {
        let id: UInt64
        let task: Task<SaveResult, Never>
    }

    let discovery: any DirectAgentExecutableDiscovering
    let snapshotStore: any DirectAgentSnapshotStoring
    let adapterFactory: any DirectAgentAdapterFactory
    let telemetry: any DirectAgentRuntimeTelemetry
    let refreshTimeout: TimeInterval
    let staleAfter: TimeInterval
    let now: Clock

    var states: [ProviderID: ProviderRuntimeState]
    var executables: [ProviderID: DiscoveredExecutable] = [:]
    var lastGoodSnapshots: [ProviderID: UsageSnapshot] = [:]
    var refreshOperations: [ProviderID: RefreshOperation] = [:]
    var saveOperation: SaveOperation?
    private var startOperation: Task<Void, Never>?
    private var started = false
    var nextOperationID: UInt64 = 0
    var persistenceState = AgentRuntimePersistenceState.notLoaded

    public init(
        discovery: any DirectAgentExecutableDiscovering = SystemDirectAgentExecutableDiscovery(),
        snapshotStore: any DirectAgentSnapshotStoring = UsageSnapshotStore(
            fileURL: UsageSnapshotStore.defaultFileURL()
        ),
        adapterFactory: any DirectAgentAdapterFactory = LiveDirectAgentAdapterFactory(),
        telemetry: any DirectAgentRuntimeTelemetry = LocalDirectAgentRuntimeTelemetry(),
        refreshTimeout: TimeInterval = 15,
        staleAfter: TimeInterval = 300,
        now: @escaping Clock = { Date() }
    ) {
        self.discovery = discovery
        self.snapshotStore = snapshotStore
        self.adapterFactory = adapterFactory
        self.telemetry = telemetry
        self.refreshTimeout = min(max(refreshTimeout, 1), 15)
        self.staleAfter = max(staleAfter, 1)
        self.now = now

        var initialStates: [ProviderID: ProviderRuntimeState] = [:]
        for provider in ProviderID.allCases {
            initialStates[provider] = Self.initialState(for: provider)
        }
        self.states = initialStates
    }

    public func start(refreshLiveData: Bool = true) async -> DirectAgentRuntimeSnapshot {
        if started {
            return runtimeSnapshot()
        }
        if let startOperation {
            await startOperation.value
            return runtimeSnapshot()
        }

        let operation = Task { [self] in
            await performStart(refreshLiveData: refreshLiveData)
        }
        startOperation = operation
        await operation.value
        startOperation = nil
        started = true
        return runtimeSnapshot()
    }

    /// Loads only the encrypted last-good state. Provider discovery and child
    /// processes are deliberately excluded so cached meters can render first.
    public func loadCachedState() async -> DirectAgentRuntimeSnapshot {
        if persistenceState == .notLoaded {
            await loadCachedSnapshots()
        }
        return runtimeSnapshot()
    }

    public func discoverProviders() async -> DirectAgentRuntimeSnapshot {
        let discovery = discovery
        async let codexResult = Self.performDiscovery(.codex, using: discovery)
        async let claudeResult = Self.performDiscovery(.claude, using: discovery)
        let results = await (codexResult, claudeResult)
        await applyDiscoveryResult(results.0, provider: .codex)
        await applyDiscoveryResult(results.1, provider: .claude)
        return runtimeSnapshot()
    }

    public func refreshAll() async -> DirectAgentRuntimeSnapshot {
        await refreshProviders(ProviderID.allCases)
        return runtimeSnapshot()
    }

    public func refresh(_ provider: ProviderID) async -> ProviderRuntimeState {
        if let operation = refreshOperations[provider] {
            return await completeRefresh(operation, provider: provider)
        }
        if executables[provider] == nil {
            await discoverProvider(provider)
        }
        guard let executable = executables[provider] else {
            return resolvedState(for: provider)
        }

        let operation = makeRefreshOperation(provider: provider, executable: executable)
        refreshOperations[provider] = operation
        setConnectionState(.connecting, for: provider)
        return await completeRefresh(operation, provider: provider)
    }

    public func ingestClaudeStatusLine(
        _ data: Data,
        capturedAt: Date = Date()
    ) async -> ProviderRuntimeState {
        do {
            try await adapterFactory.ingestClaudeStatusLine(data, capturedAt: capturedAt)
        } catch {
            let providerError = ProviderError.wrapping(error, provider: .claude)
            await applyFailure(providerError, provider: .claude, operation: "status-line")
            return resolvedState(for: .claude)
        }
        return await refresh(.claude)
    }

    public func providerState(for provider: ProviderID) -> ProviderRuntimeState {
        resolvedState(for: provider)
    }

    public func runtimeSnapshot() -> DirectAgentRuntimeSnapshot {
        DirectAgentRuntimeSnapshot(
            providers: ProviderID.allCases.map(resolvedState(for:)),
            persistenceState: persistenceState,
            capturedAt: now()
        )
    }
}
