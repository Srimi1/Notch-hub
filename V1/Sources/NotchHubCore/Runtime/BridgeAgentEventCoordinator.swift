import CryptoKit
import Foundation

public struct BridgeAgentStateSnapshot: Sendable, Equatable {
    public let sessions: [AgentSession]
    public let pendingApproval: ApprovalRequest?

    public init(sessions: [AgentSession], pendingApproval: ApprovalRequest?) {
        self.sessions = sessions
        self.pendingApproval = pendingApproval
    }
}

/// Converts authenticated bridge messages into short-lived application state.
/// Session and approval metadata never leaves memory and terminal sessions are
/// removed after a small notification window.
public actor BridgeAgentEventCoordinator {
    private static let maximumTrackedSessions = 512

    public typealias Clock = @Sendable () -> Date
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias StateHandler = @MainActor @Sendable (BridgeAgentStateSnapshot) -> Void
    public typealias ClaudeStatusHandler = @Sendable (BridgeStatusLineEvent) async -> Void
    public typealias DiagnosticHandler = @Sendable (ProviderError) async -> Void

    private struct PendingApproval {
        let request: ApprovalRequest
        let continuation: CheckedContinuation<BridgeTrustedDecision, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let stateHandler: StateHandler
    private let claudeStatusHandler: ClaudeStatusHandler
    private let diagnosticHandler: DiagnosticHandler
    private let terminalRetention: Duration
    private let now: Clock
    private let sleep: Sleeper

    private var sessions: [String: AgentSession] = [:]
    private var terminalRemovalTasks: [String: Task<Void, Never>] = [:]
    private var sessionEventDates: [String: Date] = [:]
    private var sessionEventOrder: [String] = []
    private var terminalSessionIDs = Set<String>()
    private var pendingApproval: PendingApproval?

    public init(
        terminalRetention: Duration = .seconds(5),
        now: @escaping Clock = { Date() },
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        stateHandler: @escaping StateHandler,
        claudeStatusHandler: @escaping ClaudeStatusHandler,
        diagnosticHandler: @escaping DiagnosticHandler
    ) {
        self.terminalRetention = terminalRetention
        self.now = now
        self.sleep = sleep
        self.stateHandler = stateHandler
        self.claudeStatusHandler = claudeStatusHandler
        self.diagnosticHandler = diagnosticHandler
    }

    public func handle(_ envelope: BridgeRequestEnvelope) async -> BridgeTrustedDecision {
        switch envelope.event {
        case let .session(event):
            do {
                try await apply(event)
            } catch {
                await diagnosticHandler(ProviderError.wrapping(error, provider: event.provider))
                return .abstain(.invalidInput)
            }
            return .abstain(.awaitingTrustedResponder)
        case let .statusLine(event):
            await claudeStatusHandler(event)
            return .abstain(.awaitingTrustedResponder)
        case let .approval(approval):
            return await awaitDecision(for: approval)
        }
    }

    public func respond(to approvalID: String, decision: ApprovalDecision) async throws {
        guard let pendingApproval, pendingApproval.request.id == approvalID else {
            throw ProviderError.approvalNotFound
        }
        guard pendingApproval.request.expiresAt > now() else {
            await resolvePending(.abstain(.timedOut))
            throw ProviderError.approvalExpired
        }

        let trustedDecision: BridgeTrustedDecision = switch decision {
        case .allowOnce: .allowOnce
        case .deny: .deny
        }
        await resolvePending(trustedDecision)
    }

    public func stop() async {
        for task in terminalRemovalTasks.values {
            task.cancel()
        }
        terminalRemovalTasks.removeAll()
        sessions.removeAll()
        sessionEventDates.removeAll()
        sessionEventOrder.removeAll()
        terminalSessionIDs.removeAll()
        if pendingApproval != nil {
            await resolvePending(.abstain(.unavailable), publishState: false)
        }
        await publishState()
    }

    public func snapshot() -> BridgeAgentStateSnapshot {
        makeSnapshot()
    }

    private func apply(_ event: BridgeSessionEvent) async throws {
        let id = scopedIdentifier(provider: event.provider, value: event.sessionID)
        guard shouldApply(event, sessionID: id) else { return }
        try prepareTracking(for: id, provider: event.provider)
        sessionEventDates[id] = event.occurredAt
        terminalRemovalTasks[id]?.cancel()
        terminalRemovalTasks[id] = nil

        switch event.state {
        case .started, .running, .waitingForApproval:
            terminalSessionIDs.remove(id)
            let previous = sessions[id]
            let status: AgentSession.Status = event.state == .waitingForApproval ? .waitingForApproval : .running
            let session = try makeSession(
                id: id,
                event: event,
                status: status,
                startedAt: previous?.startedAt ?? event.occurredAt
            )
            sessions[id] = session
            await publishState()
        case .completed, .ended:
            terminalSessionIDs.insert(id)
            if pendingApproval?.request.sessionID == id {
                await resolvePending(.abstain(.unavailable), publishState: false)
            }
            try await retainTerminalSession(id: id, event: event, status: .finished)
        case .failed:
            terminalSessionIDs.insert(id)
            if pendingApproval?.request.sessionID == id {
                await resolvePending(.abstain(.unavailable), publishState: false)
            }
            try await retainTerminalSession(id: id, event: event, status: .failed)
        case .interrupted:
            terminalSessionIDs.insert(id)
            if pendingApproval?.request.sessionID == id {
                await resolvePending(.abstain(.unavailable), publishState: false)
            }
            try await retainTerminalSession(id: id, event: event, status: .interrupted)
        }
    }

    private func retainTerminalSession(
        id: String,
        event: BridgeSessionEvent,
        status: AgentSession.Status
    ) async throws {
        let startedAt = min(sessions[id]?.startedAt ?? event.occurredAt, event.occurredAt)
        let session = try makeSession(id: id, event: event, status: status, startedAt: startedAt)
        sessions[id] = session
        await publishState()

        let retention = terminalRetention
        terminalRemovalTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: retention)
            } catch {
                return
            }
            await self?.removeTerminalSession(id: id, updatedAt: session.updatedAt)
        }
    }

    private func removeTerminalSession(id: String, updatedAt: Date) async {
        guard let session = sessions[id], session.updatedAt == updatedAt, !session.status.isActive else {
            return
        }
        sessions[id] = nil
        terminalRemovalTasks[id] = nil
        await publishState()
    }

    private func makeSession(
        id: String,
        event: BridgeSessionEvent,
        status: AgentSession.Status,
        startedAt: Date
    ) throws -> AgentSession {
        try AgentSession(
            id: id,
            provider: event.provider,
            projectName: event.projectLabel,
            status: status,
            startedAt: startedAt,
            updatedAt: max(event.occurredAt, startedAt)
        )
    }

    private func awaitDecision(for bridgeRequest: BridgeApprovalRequest) async -> BridgeTrustedDecision {
        guard pendingApproval == nil else {
            return .abstain(.awaitingTrustedResponder)
        }
        let receivedAt = now()
        let expiresAt = min(bridgeRequest.expiresAt, receivedAt.addingTimeInterval(ApprovalRequest.maximumLifetime))
        guard expiresAt > receivedAt else {
            return .abstain(.timedOut)
        }
        let request: ApprovalRequest
        do {
            request = try makeApproval(bridgeRequest, receivedAt: receivedAt, expiresAt: expiresAt)
        } catch {
            await diagnosticHandler(ProviderError.wrapping(error, provider: bridgeRequest.provider))
            return .abstain(.invalidInput)
        }

        do {
            try markSessionWaiting(for: request)
        } catch {
            await diagnosticHandler(ProviderError.wrapping(error, provider: bridgeRequest.provider))
            return .abstain(.invalidInput)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let approvalID = request.id
                let timeoutTask = Task { [weak self, sleep] in
                    guard let self else { return }
                    let currentDate = await self.currentDate()
                    let interval = max(expiresAt.timeIntervalSince(currentDate), 0)
                    do {
                        try await sleep(.seconds(interval))
                    } catch {
                        return
                    }
                    await self.expireApproval(id: approvalID)
                }
                pendingApproval = PendingApproval(
                    request: request,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { @MainActor [stateHandler, snapshot = makeSnapshot()] in
                    stateHandler(snapshot)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelApproval(id: request.id)
            }
        }
    }

    private func makeApproval(
        _ value: BridgeApprovalRequest,
        receivedAt: Date,
        expiresAt: Date
    ) throws -> ApprovalRequest {
        try ApprovalRequest(
            id: scopedIdentifier(provider: value.provider, value: value.approvalID),
            provider: value.provider,
            sessionID: scopedIdentifier(provider: value.provider, value: value.sessionID),
            projectName: value.projectLabel,
            actionCategory: actionCategory(value.actionCategory),
            rawPreview: value.targetLabel,
            risk: approvalRisk(value.risk),
            receivedAt: receivedAt,
            expiresAt: expiresAt
        )
    }

    private func expireApproval(id: String) async {
        guard pendingApproval?.request.id == id else { return }
        await resolvePending(.abstain(.timedOut))
    }

    private func cancelApproval(id: String) async {
        guard pendingApproval?.request.id == id else { return }
        await resolvePending(.abstain(.unavailable))
    }

    private func resolvePending(
        _ decision: BridgeTrustedDecision,
        publishState shouldPublishState: Bool = true
    ) async {
        guard let pendingApproval else { return }
        self.pendingApproval = nil
        pendingApproval.timeoutTask.cancel()
        await restoreRunningSession(for: pendingApproval.request)
        pendingApproval.continuation.resume(returning: decision)
        if shouldPublishState {
            await publishState()
        }
    }

    private func publishState() async {
        await stateHandler(makeSnapshot())
    }

    private func makeSnapshot() -> BridgeAgentStateSnapshot {
        BridgeAgentStateSnapshot(
            sessions: sessions.values.sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id < $1.id
                }
                return $0.updatedAt > $1.updatedAt
            },
            pendingApproval: pendingApproval?.request
        )
    }

    private func currentDate() -> Date {
        now()
    }

    private func shouldApply(_ event: BridgeSessionEvent, sessionID: String) -> Bool {
        if let previousDate = sessionEventDates[sessionID], event.occurredAt < previousDate {
            return false
        }
        if terminalSessionIDs.contains(sessionID) {
            switch event.state {
            case .completed, .failed, .interrupted, .ended:
                return true
            case .started, .running, .waitingForApproval:
                return false
            }
        }
        return true
    }

    private func prepareTracking(for sessionID: String, provider: ProviderID) throws {
        guard sessionEventDates[sessionID] == nil else { return }
        if sessionEventDates.count >= Self.maximumTrackedSessions,
           let removableIndex = sessionEventOrder.firstIndex(where: { sessions[$0] == nil })
        {
            let removedID = sessionEventOrder.remove(at: removableIndex)
            sessionEventDates[removedID] = nil
            terminalSessionIDs.remove(removedID)
        }
        guard sessionEventDates.count < Self.maximumTrackedSessions else {
            throw ProviderError.invalidPayload(provider: provider, field: "active session limit")
        }
        sessionEventOrder.append(sessionID)
    }

    private func markSessionWaiting(for request: ApprovalRequest) throws {
        try prepareTracking(for: request.sessionID, provider: request.provider)
        sessionEventDates[request.sessionID] = max(
            sessionEventDates[request.sessionID] ?? request.receivedAt,
            request.receivedAt
        )
        let previous = sessions[request.sessionID]
        let startedAt = min(previous?.startedAt ?? request.receivedAt, request.receivedAt)
        sessions[request.sessionID] = try AgentSession(
            id: request.sessionID,
            provider: request.provider,
            projectName: request.projectName ?? previous?.projectName,
            status: .waitingForApproval,
            startedAt: startedAt,
            updatedAt: max(request.receivedAt, startedAt)
        )
    }

    private func restoreRunningSession(for request: ApprovalRequest) async {
        guard let previous = sessions[request.sessionID], previous.status == .waitingForApproval else {
            return
        }
        do {
            sessions[request.sessionID] = try AgentSession(
                id: previous.id,
                provider: previous.provider,
                projectName: previous.projectName,
                status: .running,
                startedAt: previous.startedAt,
                updatedAt: max(now(), previous.startedAt)
            )
        } catch {
            sessions[request.sessionID] = nil
            await diagnosticHandler(ProviderError.wrapping(error, provider: request.provider))
        }
    }

    private func scopedIdentifier(provider: ProviderID, value: String) -> String {
        var scopedData = Data(provider.rawValue.utf8)
        scopedData.append(0)
        scopedData.append(Data(value.utf8))
        let digest = SHA256.hash(data: scopedData).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue):\(digest)"
    }

    private func actionCategory(_ category: BridgeActionCategory) -> ApprovalActionCategory {
        switch category {
        case .fileRead, .fileWrite: .fileChange
        case .processExecution: .command
        case .networkAccess: .network
        case .versionControl, .systemChange: .tool
        case .unknown: .unknown
        }
    }

    private func approvalRisk(_ risk: BridgeRiskLevel) -> ApprovalRisk {
        switch risk {
        case .low: .low
        case .elevated: .moderate
        case .high: .high
        }
    }
}
