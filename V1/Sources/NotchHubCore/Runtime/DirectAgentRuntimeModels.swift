import Foundation

public enum AgentRuntimeSnapshotSource: String, Codable, Hashable, Sendable {
    case encryptedCache
    case liveProvider
}

public enum AgentRuntimePersistenceState: String, Codable, Hashable, Sendable {
    case notLoaded
    case available
    case failed
}

public struct ProviderRuntimeState: Codable, Hashable, Identifiable, Sendable {
    public let provider: ProviderID
    public let connectionState: ProviderConnectionState
    public let usageSnapshot: UsageSnapshot?
    public let snapshotSource: AgentRuntimeSnapshotSource?
    public let executableSource: ExecutableSource?

    public var id: ProviderID {
        provider
    }

    public init(
        provider: ProviderID,
        connectionState: ProviderConnectionState,
        usageSnapshot: UsageSnapshot?,
        snapshotSource: AgentRuntimeSnapshotSource?,
        executableSource: ExecutableSource?
    ) {
        self.provider = provider
        self.connectionState = connectionState
        self.usageSnapshot = usageSnapshot
        self.snapshotSource = snapshotSource
        self.executableSource = executableSource
    }
}

public struct DirectAgentRuntimeSnapshot: Codable, Hashable, Sendable {
    public let providers: [ProviderRuntimeState]
    public let persistenceState: AgentRuntimePersistenceState
    public let capturedAt: Date

    public init(
        providers: [ProviderRuntimeState],
        persistenceState: AgentRuntimePersistenceState,
        capturedAt: Date
    ) {
        self.providers = providers
        self.persistenceState = persistenceState
        self.capturedAt = capturedAt
    }

    public func state(for provider: ProviderID) -> ProviderRuntimeState? {
        providers.first { $0.provider == provider }
    }
}

public struct DirectAgentRuntimeTelemetryEvent: Hashable, Sendable {
    public let severity: TelemetrySeverity
    public let code: String
    public let summary: String

    public init(severity: TelemetrySeverity, code: String, summary: String) {
        self.severity = severity
        self.code = code
        self.summary = summary
    }
}
