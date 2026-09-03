import Foundation

public protocol DirectAgentExecutableDiscovering: Sendable {
    func discover(_ provider: ProviderID) throws -> DiscoveredExecutable?
}

public protocol DirectAgentSnapshotStoring: Sendable {
    func load() async throws -> [ProviderID: UsageSnapshot]
    func save(_ snapshots: [ProviderID: UsageSnapshot]) async throws
}

public protocol DirectAgentAdapterFactory: Sendable {
    /// Implementations must return an adapter whose fetch operation terminates
    /// within `timeout`, including complete cleanup of provider child processes.
    func makeAdapter(
        for provider: ProviderID,
        executable: DiscoveredExecutable,
        timeout: TimeInterval
    ) async throws -> any UsageProviderAdapter

    func ingestClaudeStatusLine(_ data: Data, capturedAt: Date) async throws
}

public protocol DirectAgentRuntimeTelemetry: Sendable {
    func record(_ event: DirectAgentRuntimeTelemetryEvent) async
}

extension UsageSnapshotStore: DirectAgentSnapshotStoring {}

public struct SystemDirectAgentExecutableDiscovery: DirectAgentExecutableDiscovering {
    private let discovery: ExecutableDiscovery
    private let environment: ExecutableDiscoveryEnvironment

    public init(
        discovery: ExecutableDiscovery = ExecutableDiscovery(),
        environment: ExecutableDiscoveryEnvironment = .current()
    ) {
        self.discovery = discovery
        self.environment = environment
    }

    public func discover(_ provider: ProviderID) throws -> DiscoveredExecutable? {
        try discovery.discover(provider, environment: environment)
    }
}

public struct LocalDirectAgentRuntimeTelemetry: DirectAgentRuntimeTelemetry {
    public let console: LocalTelemetryConsole

    public init(console: LocalTelemetryConsole = LocalTelemetryConsole()) {
        self.console = console
    }

    public func record(_ event: DirectAgentRuntimeTelemetryEvent) async {
        await console.record(
            severity: event.severity,
            category: "agent-runtime",
            code: event.code,
            summary: event.summary
        )
    }
}

public struct LiveDirectAgentAdapterFactory: DirectAgentAdapterFactory {
    private let claudeAdapter: ClaudeStatusLineUsageAdapter
    private let codexEnvironment: [String: String]

    public init(
        claudeAdapter: ClaudeStatusLineUsageAdapter = ClaudeStatusLineUsageAdapter(),
        codexEnvironment: [String: String] = CodexEnvironment.minimumInherited()
    ) {
        self.claudeAdapter = claudeAdapter
        self.codexEnvironment = codexEnvironment
    }

    public func makeAdapter(
        for provider: ProviderID,
        executable: DiscoveredExecutable,
        timeout: TimeInterval
    ) async throws -> any UsageProviderAdapter {
        guard executable.provider == provider else {
            throw ProviderError.invalidPayload(provider: provider, field: "discovered executable provider")
        }

        switch provider {
        case .codex:
            return CodexAppServerAdapter(
                executableURL: executable.url,
                timeout: min(max(timeout, 1), 15),
                environment: codexEnvironment
            )
        case .claude:
            return claudeAdapter
        }
    }

    public func ingestClaudeStatusLine(_ data: Data, capturedAt: Date) async throws {
        try await claudeAdapter.ingest(data, capturedAt: capturedAt)
    }
}
