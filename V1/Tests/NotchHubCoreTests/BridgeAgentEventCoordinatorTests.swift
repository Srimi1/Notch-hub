import Foundation
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

@Suite("Bridge agent event coordinator")
struct BridgeAgentEventCoordinatorTests {
    @Test("Session metadata is memory-only and terminal sessions expire")
    @MainActor
    func sessionLifecycle() async throws {
        let recorder = BridgeStateRecorder()
        let statusRecorder = BridgeStatusRecorder()
        let sleepGate = BridgeSleepGate()
        let coordinator = makeCoordinator(
            recorder: recorder,
            statusRecorder: statusRecorder,
            terminalRetention: .milliseconds(20),
            sleep: { duration in try await sleepGate.sleep(duration) }
        )
        let startedAt = Date()

        _ = await coordinator.handle(
            try envelope(sessionState: .started, occurredAt: startedAt)
        )
        var snapshot = await coordinator.snapshot()
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].status == .running)
        #expect(snapshot.sessions[0].projectName == "FixtureProject")

        _ = await coordinator.handle(
            try envelope(sessionState: .completed, occurredAt: startedAt.addingTimeInterval(1))
        )
        snapshot = await coordinator.snapshot()
        #expect(snapshot.sessions.first?.status == .finished)

        try await waitUntil { await sleepGate.hasWaiter }
        await sleepGate.resume()
        try await waitUntil { await coordinator.snapshot().sessions.isEmpty }
    }

    @Test("Approval is one-time and unknown actions receive critical review")
    @MainActor
    func oneTimeApproval() async throws {
        let recorder = BridgeStateRecorder()
        let coordinator = makeCoordinator(recorder: recorder, statusRecorder: BridgeStatusRecorder())
        let approvalEnvelope = try envelope(approvalID: "approval-one", category: .unknown)
        let decisionTask = Task { await coordinator.handle(approvalEnvelope) }

        try await waitUntil { await coordinator.snapshot().pendingApproval != nil }
        let pending = try #require(await coordinator.snapshot().pendingApproval)
        #expect(pending.risk == .critical)
        #expect(pending.preview == "Unrecognized action")
        #expect(await coordinator.snapshot().sessions.first?.status == .waitingForApproval)

        try await coordinator.respond(to: pending.id, decision: .allowOnce)
        #expect(await decisionTask.value == .allowOnce)
        #expect(await coordinator.snapshot().pendingApproval == nil)
        #expect(await coordinator.snapshot().sessions.first?.status == .running)
        await #expect(throws: ProviderError.approvalNotFound) {
            try await coordinator.respond(to: pending.id, decision: .allowOnce)
        }
    }

    @Test("Out-of-order async lifecycle events cannot reopen an ended session")
    @MainActor
    func terminalPrecedence() async throws {
        let coordinator = makeCoordinator(
            recorder: BridgeStateRecorder(),
            statusRecorder: BridgeStatusRecorder(),
            terminalRetention: .seconds(1)
        )
        let startedAt = Date()
        _ = await coordinator.handle(try envelope(sessionState: .started, occurredAt: startedAt))
        _ = await coordinator.handle(
            try envelope(sessionState: .ended, occurredAt: startedAt.addingTimeInterval(2))
        )
        _ = await coordinator.handle(
            try envelope(sessionState: .running, occurredAt: startedAt.addingTimeInterval(1))
        )

        #expect(await coordinator.snapshot().sessions.first?.status == .finished)
    }

    @Test("A second simultaneous approval abstains to the native provider prompt")
    @MainActor
    func simultaneousApprovals() async throws {
        let coordinator = makeCoordinator(
            recorder: BridgeStateRecorder(),
            statusRecorder: BridgeStatusRecorder()
        )
        let firstTask = Task { await coordinator.handle(try envelope(approvalID: "approval-one")) }
        try await waitUntil { await coordinator.snapshot().pendingApproval != nil }

        let secondDecision = await coordinator.handle(try envelope(approvalID: "approval-two"))
        #expect(secondDecision == .abstain(.awaitingTrustedResponder))

        let pending = try #require(await coordinator.snapshot().pendingApproval)
        try await coordinator.respond(to: pending.id, decision: .deny)
        #expect(try await firstTask.value == .deny)
    }

    @Test("Expired approval abstains without presenting controls")
    @MainActor
    func expiredApproval() async throws {
        let coordinator = makeCoordinator(
            recorder: BridgeStateRecorder(),
            statusRecorder: BridgeStatusRecorder()
        )
        let request = try bridgeApproval(
            approvalID: "expired",
            category: .processExecution,
            expiresAt: Date().addingTimeInterval(-1)
        )
        let envelope = try BridgeRequestEnvelope(nonce: "expired-nonce", event: .approval(request))

        #expect(await coordinator.handle(envelope) == .abstain(.timedOut))
        #expect(await coordinator.snapshot().pendingApproval == nil)
    }

    @Test("Claude status-line event is forwarded only in sanitized form")
    @MainActor
    func statusLineForwarding() async throws {
        let statusRecorder = BridgeStatusRecorder()
        let coordinator = makeCoordinator(
            recorder: BridgeStateRecorder(),
            statusRecorder: statusRecorder
        )
        let status = try BridgeStatusLineEvent(
            provider: .claude,
            sessionID: "session-1",
            rateLimits: [
                try BridgeRateLimitWindow(id: .fiveHour, usedPercent: 42, resetsAt: nil),
            ],
            capturedAt: Date()
        )
        let request = try BridgeRequestEnvelope(nonce: "status-nonce", event: .statusLine(status))

        _ = await coordinator.handle(request)
        #expect(await statusRecorder.events == [status])
    }

    @MainActor
    private func makeCoordinator(
        recorder: BridgeStateRecorder,
        statusRecorder: BridgeStatusRecorder,
        terminalRetention: Duration = .seconds(5),
        sleep: @escaping BridgeAgentEventCoordinator.Sleeper = { try await Task.sleep(for: $0) }
    ) -> BridgeAgentEventCoordinator {
        let diagnosticRecorder = BridgeDiagnosticRecorder()
        return BridgeAgentEventCoordinator(
            terminalRetention: terminalRetention,
            sleep: sleep,
            stateHandler: { snapshot in recorder.snapshots.append(snapshot) },
            claudeStatusHandler: { event in await statusRecorder.record(event) },
            diagnosticHandler: { error in await diagnosticRecorder.record(error) }
        )
    }

    private func envelope(
        sessionState: BridgeLifecycleState,
        occurredAt: Date
    ) throws -> BridgeRequestEnvelope {
        let event = try BridgeSessionEvent(
            eventID: "event-\(sessionState.rawValue)",
            provider: .codex,
            sessionID: "session-1",
            state: sessionState,
            projectLabel: "/fixture/FixtureProject",
            occurredAt: occurredAt
        )
        return try BridgeRequestEnvelope(nonce: "nonce-\(sessionState.rawValue)", event: .session(event))
    }

    private func envelope(
        approvalID: String,
        category: BridgeActionCategory = .fileWrite
    ) throws -> BridgeRequestEnvelope {
        let request = try bridgeApproval(
            approvalID: approvalID,
            category: category,
            expiresAt: Date().addingTimeInterval(10)
        )
        return try BridgeRequestEnvelope(nonce: "nonce-\(approvalID)", event: .approval(request))
    }

    private func bridgeApproval(
        approvalID: String,
        category: BridgeActionCategory,
        expiresAt: Date
    ) throws -> BridgeApprovalRequest {
        try BridgeApprovalRequest(
            approvalID: approvalID,
            provider: .codex,
            sessionID: "session-1",
            projectLabel: "/fixture/FixtureProject",
            actionCategory: category,
            targetLabel: "sensitive arguments are never forwarded",
            expiresAt: expiresAt
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for bridge coordinator state")
    }
}

@MainActor
private final class BridgeStateRecorder {
    var snapshots: [BridgeAgentStateSnapshot] = []
}

private actor BridgeStatusRecorder {
    var events: [BridgeStatusLineEvent] = []

    func record(_ event: BridgeStatusLineEvent) {
        events.append(event)
    }
}

private actor BridgeDiagnosticRecorder {
    var errors: [ProviderError] = []

    func record(_ error: ProviderError) {
        errors.append(error)
    }
}

private actor BridgeSleepGate {
    private var waiter: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool {
        waiter != nil
    }

    func sleep(_: Duration) async throws {
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resume() {
        waiter?.resume()
        waiter = nil
    }
}
