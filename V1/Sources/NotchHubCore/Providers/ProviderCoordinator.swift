import Foundation

public actor ProviderCoordinator {
    public typealias Clock = @Sendable () -> Date

    private struct RefreshOperation: Sendable {
        let id: UInt64
        let task: Task<UsageSnapshot, any Error>
    }

    private let adapters: [ProviderID: any UsageProviderAdapter]
    private let approvalResponders: [ProviderID: any ApprovalResponder]
    private let staleAfter: TimeInterval
    private let now: Clock

    private var snapshots: [ProviderID: UsageSnapshot] = [:]
    private var connectionStates: [ProviderID: ProviderConnectionState] = [:]
    private var refreshOperations: [ProviderID: RefreshOperation] = [:]
    private var nextRefreshID: UInt64 = 0
    private var sessionStorage: [ProviderID: [String: AgentSession]] = [:]
    private var approvalStorage: [String: ApprovalRequest] = [:]
    private var approvalResponsesInFlight = Set<String>()

    public init(
        adapters: [any UsageProviderAdapter],
        approvalResponders: [any ApprovalResponder] = [],
        staleAfter: TimeInterval = 300,
        now: @escaping Clock = { Date() }
    ) {
        self.adapters = Self.indexAdapters(adapters)
        self.approvalResponders = Self.indexResponders(approvalResponders)
        self.staleAfter = max(staleAfter, 1)
        self.now = now
    }

    public func refresh(_ provider: ProviderID) async throws -> UsageSnapshot {
        if let existingOperation = refreshOperations[provider] {
            return try await completeRefreshOperation(existingOperation, provider: provider)
        }

        guard let adapter = adapters[provider] else {
            let error = ProviderError.adapterUnavailable(provider: provider)
            recordFailure(error, for: provider)
            throw error
        }

        connectionStates[provider] = .connecting
        nextRefreshID &+= 1
        let operation = RefreshOperation(
            id: nextRefreshID,
            task: Task { try await adapter.fetchUsage() }
        )
        refreshOperations[provider] = operation

        return try await completeRefreshOperation(operation, provider: provider)
    }

    public func refreshAll() async -> [ProviderID: Result<UsageSnapshot, ProviderError>] {
        let providers = Array(adapters.keys)
        return await withTaskGroup(
            of: (ProviderID, Result<UsageSnapshot, ProviderError>).self,
            returning: [ProviderID: Result<UsageSnapshot, ProviderError>].self
        ) { group in
            for provider in providers {
                group.addTask { [self] in
                    do {
                        let snapshot = try await refresh(provider)
                        return (provider, .success(snapshot))
                    } catch {
                        return (provider, .failure(ProviderError.wrapping(error, provider: provider)))
                    }
                }
            }

            var results: [ProviderID: Result<UsageSnapshot, ProviderError>] = [:]
            for await (provider, result) in group {
                results[provider] = result
            }
            return results
        }
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        snapshots[provider]
    }

    public func connectionState(for provider: ProviderID) -> ProviderConnectionState {
        if let snapshot = snapshots[provider], snapshot.isStale(at: now(), after: staleAfter) {
            let storedReason: ProviderError? = if case let .stale(_, reason) = connectionStates[provider] {
                reason
            } else {
                nil
            }
            return .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: storedReason)
        }
        return connectionStates[provider] ?? .notDetected
    }

    public func updateConnectionState(_ state: ProviderConnectionState, for provider: ProviderID) {
        connectionStates[provider] = state
    }

    public func apply(_ event: SessionEvent) {
        switch event {
        case let .upserted(session):
            upsertSession(session)
        case let .removed(provider, sessionID):
            removeSession(provider: provider, sessionID: sessionID)
        }
    }

    public func upsertSession(_ session: AgentSession) {
        sessionStorage[session.provider, default: [:]][session.id] = session
    }

    public func removeSession(provider: ProviderID, sessionID: String) {
        sessionStorage[provider]?[sessionID] = nil
    }

    public func sessions(for provider: ProviderID? = nil) -> [AgentSession] {
        let sessions: [AgentSession] = if let provider {
            Array(sessionStorage[provider, default: [:]].values)
        } else {
            sessionStorage.values.flatMap(\.values)
        }
        return sessions.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.id < $1.id
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func upsertApproval(_ approval: ApprovalRequest) {
        purgeExpiredApprovals()
        guard !approvalResponsesInFlight.contains(approval.id) else {
            return
        }
        approvalStorage[approval.id] = approval
    }

    public func removeApproval(id: String) {
        approvalStorage[id] = nil
        approvalResponsesInFlight.remove(id)
    }

    public func pendingApprovals(for provider: ProviderID? = nil) -> [ApprovalRequest] {
        purgeExpiredApprovals()
        return approvalStorage.values
            .filter { provider == nil || $0.provider == provider }
            .sorted {
                if $0.receivedAt == $1.receivedAt {
                    return $0.id < $1.id
                }
                return $0.receivedAt < $1.receivedAt
            }
    }

    public func respond(to requestID: String, decision: ApprovalDecision) async throws {
        guard let request = approvalStorage[requestID] else {
            throw ProviderError.approvalNotFound
        }
        guard request.expiresAt > now() else {
            approvalStorage[requestID] = nil
            throw ProviderError.approvalExpired
        }
        guard !approvalResponsesInFlight.contains(requestID) else {
            throw ProviderError.approvalInProgress
        }
        guard let responder = approvalResponders[request.provider] else {
            throw ProviderError.approvalResponderUnavailable(provider: request.provider)
        }

        approvalResponsesInFlight.insert(requestID)
        do {
            try await responder.respond(to: request, decision: decision)
            approvalStorage[requestID] = nil
            approvalResponsesInFlight.remove(requestID)
        } catch {
            approvalResponsesInFlight.remove(requestID)
            throw ProviderError.wrapping(error, provider: request.provider)
        }
    }

    public func purgeExpiredApprovals() {
        let currentDate = now()
        let expiredIDs = approvalStorage.values
            .filter { $0.expiresAt <= currentDate }
            .map(\.id)
        for id in expiredIDs {
            approvalStorage[id] = nil
            approvalResponsesInFlight.remove(id)
        }
    }

    private func finishRefresh(
        _ snapshot: UsageSnapshot,
        expectedProvider: ProviderID,
        operationID: UInt64
    ) throws -> UsageSnapshot {
        guard snapshot.provider == expectedProvider else {
            let error = ProviderError.invalidPayload(provider: expectedProvider, field: "provider identifier")
            if refreshOperations[expectedProvider]?.id == operationID {
                refreshOperations[expectedProvider] = nil
                recordFailure(error, for: expectedProvider)
            }
            throw error
        }

        guard refreshOperations[expectedProvider]?.id == operationID else {
            return snapshot
        }

        refreshOperations[expectedProvider] = nil
        snapshots[expectedProvider] = snapshot
        connectionStates[expectedProvider] = .connected(lastRefresh: snapshot.capturedAt)
        return snapshot
    }

    private func completeRefreshOperation(
        _ operation: RefreshOperation,
        provider: ProviderID
    ) async throws -> UsageSnapshot {
        do {
            let snapshot = try await operation.task.value
            return try finishRefresh(
                snapshot,
                expectedProvider: provider,
                operationID: operation.id
            )
        } catch {
            return try finishRefreshFailure(
                error,
                provider: provider,
                operationID: operation.id
            )
        }
    }

    private func finishRefreshFailure(
        _ error: any Error,
        provider: ProviderID,
        operationID: UInt64
    ) throws -> UsageSnapshot {
        let providerError = ProviderError.wrapping(error, provider: provider)
        if refreshOperations[provider]?.id == operationID {
            refreshOperations[provider] = nil
            recordFailure(providerError, for: provider)
        }
        throw providerError
    }

    private func recordFailure(_ error: ProviderError, for provider: ProviderID) {
        if let snapshot = snapshots[provider] {
            connectionStates[provider] = .stale(
                lastSuccessfulRefresh: snapshot.capturedAt,
                reason: error
            )
        } else if case .signedOut = error {
            connectionStates[provider] = .signedOut
        } else {
            connectionStates[provider] = .failed(error)
        }
    }

    private static func indexAdapters(
        _ values: [any UsageProviderAdapter]
    ) -> [ProviderID: any UsageProviderAdapter] {
        var result: [ProviderID: any UsageProviderAdapter] = [:]
        for value in values {
            result[value.provider] = value
        }
        return result
    }

    private static func indexResponders(
        _ values: [any ApprovalResponder]
    ) -> [ProviderID: any ApprovalResponder] {
        var result: [ProviderID: any ApprovalResponder] = [:]
        for value in values {
            result[value.provider] = value
        }
        return result
    }
}
