import Foundation
import Testing
@testable import NotchHubCore

@Suite("Provider coordinator")
struct CoordinatorTests {
    @Test("Concurrent refresh requests share one adapter operation")
    func refreshCoalescing() async throws {
        let snapshot = try fixtureSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 1000))
        let adapter = FixtureUsageProviderAdapter(
            provider: .codex,
            results: [.success(snapshot)],
            delay: .milliseconds(75)
        )
        let coordinator = ProviderCoordinator(
            adapters: [adapter],
            now: { Date(timeIntervalSince1970: 1001) }
        )

        async let first = coordinator.refresh(.codex)
        async let second = coordinator.refresh(.codex)
        let results = try await [first, second]

        #expect(results == [snapshot, snapshot])
        #expect(await adapter.fetchCount() == 1)
        #expect(await coordinator.connectionState(for: .codex) == .connected(lastRefresh: snapshot.capturedAt))
    }

    @Test("A failed refresh retains the last good snapshot as stale")
    func staleRetention() async throws {
        let snapshot = try fixtureSnapshot(provider: .claude, capturedAt: Date(timeIntervalSince1970: 2000))
        let adapter = FixtureUsageProviderAdapter(
            provider: .claude,
            results: [.success(snapshot), .failure(.offline(provider: .claude))]
        )
        let coordinator = ProviderCoordinator(adapters: [adapter])

        _ = try await coordinator.refresh(.claude)
        do {
            _ = try await coordinator.refresh(.claude)
            Issue.record("Expected the second refresh to fail")
        } catch let error as ProviderError {
            #expect(error == .offline(provider: .claude))
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(await coordinator.snapshot(for: .claude) == snapshot)
        #expect(
            await coordinator.connectionState(for: .claude)
                == .stale(lastSuccessfulRefresh: snapshot.capturedAt, reason: .offline(provider: .claude))
        )
    }

    @Test("Snapshots age into a stale state without another process launch")
    func ageBasedStaleness() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1000)
        let snapshot = try fixtureSnapshot(provider: .codex, capturedAt: capturedAt)
        let adapter = FixtureUsageProviderAdapter(provider: .codex, results: [.success(snapshot)])
        let coordinator = ProviderCoordinator(
            adapters: [adapter],
            staleAfter: 60,
            now: { Date(timeIntervalSince1970: 1061) }
        )

        _ = try await coordinator.refresh(.codex)
        #expect(
            await coordinator.connectionState(for: .codex)
                == .stale(lastSuccessfulRefresh: capturedAt, reason: nil)
        )
    }

    @Test("Missing adapters fail without launching anything")
    func missingAdapter() async {
        let coordinator = ProviderCoordinator(adapters: [])
        do {
            _ = try await coordinator.refresh(.codex)
            Issue.record("Expected a missing adapter error")
        } catch let error as ProviderError {
            #expect(error == .adapterUnavailable(provider: .codex))
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("Adapters cannot return a snapshot for another provider")
    func providerMismatch() async throws {
        let wrongSnapshot = try fixtureSnapshot(
            provider: .claude,
            capturedAt: Date(timeIntervalSince1970: 1000)
        )
        let adapter = FixtureUsageProviderAdapter(provider: .codex, results: [.success(wrongSnapshot)])
        let coordinator = ProviderCoordinator(adapters: [adapter])

        do {
            _ = try await coordinator.refresh(.codex)
            Issue.record("Expected provider validation failure")
        } catch let error as ProviderError {
            #expect(error == .invalidPayload(provider: .codex, field: "provider identifier"))
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await coordinator.snapshot(for: .codex) == nil)
    }

    @Test("Sessions are kept in provider-neutral recency order")
    func sessionState() async throws {
        let coordinator = ProviderCoordinator(adapters: [])
        let first = try fixtureSession(id: "one", provider: .codex, updatedAt: 10)
        let second = try fixtureSession(id: "two", provider: .claude, updatedAt: 20)

        await coordinator.apply(.upserted(first))
        await coordinator.apply(.upserted(second))
        #expect(await coordinator.sessions().map(\.id) == ["two", "one"])

        await coordinator.apply(.removed(provider: .codex, sessionID: "one"))
        #expect(await coordinator.sessions().map(\.id) == ["two"])
    }

    @Test("Approval responses are one-time and removed only after success")
    func approvalResponse() async throws {
        let responder = FixtureApprovalResponder(provider: .codex)
        let coordinator = ProviderCoordinator(
            adapters: [],
            approvalResponders: [responder],
            now: { Date(timeIntervalSince1970: 1001) }
        )
        let request = try fixtureApproval()
        await coordinator.upsertApproval(request)

        try await coordinator.respond(to: request.id, decision: .allowOnce)

        #expect(await coordinator.pendingApprovals().isEmpty)
        #expect(await responder.responses() == [.init(requestID: request.id, decision: .allowOnce)])
    }

    @Test("Responder failure retains an unexpired approval")
    func approvalFailureRetention() async throws {
        let responder = FixtureApprovalResponder(
            provider: .codex,
            error: .offline(provider: .codex)
        )
        let coordinator = ProviderCoordinator(
            adapters: [],
            approvalResponders: [responder],
            now: { Date(timeIntervalSince1970: 1001) }
        )
        let request = try fixtureApproval()
        await coordinator.upsertApproval(request)

        do {
            try await coordinator.respond(to: request.id, decision: .deny)
            Issue.record("Expected responder failure")
        } catch let error as ProviderError {
            #expect(error == .offline(provider: .codex))
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await coordinator.pendingApprovals() == [request])
    }

    @Test("Expired approvals fail closed and are discarded")
    func expiredApproval() async throws {
        let responder = FixtureApprovalResponder(provider: .codex)
        let coordinator = ProviderCoordinator(
            adapters: [],
            approvalResponders: [responder],
            now: { Date(timeIntervalSince1970: 1121) }
        )
        let request = try fixtureApproval()
        await coordinator.upsertApproval(request)

        do {
            try await coordinator.respond(to: request.id, decision: .allowOnce)
            Issue.record("Expected approval expiry")
        } catch let error as ProviderError {
            #expect(error == .approvalExpired)
        } catch {
            Issue.record("Unexpected error type")
        }
        #expect(await responder.responses().isEmpty)
    }

    private func fixtureSnapshot(provider: ProviderID, capturedAt: Date) throws -> UsageSnapshot {
        let quota = try QuotaWindow(id: "five-hour", label: "Five hour", usedPercent: 40)
        return try UsageSnapshot(provider: provider, windows: [quota], capturedAt: capturedAt)
    }

    private func fixtureSession(
        id: String,
        provider: ProviderID,
        updatedAt: TimeInterval
    ) throws -> AgentSession {
        try AgentSession(
            id: id,
            provider: provider,
            projectName: "Fixture",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func fixtureApproval() throws -> ApprovalRequest {
        try ApprovalRequest(
            id: "approval-1",
            provider: .codex,
            sessionID: "session-1",
            projectName: "Fixture",
            actionCategory: .tool,
            rawPreview: "read-file private arguments",
            risk: .low,
            receivedAt: Date(timeIntervalSince1970: 1000),
            expiresAt: Date(timeIntervalSince1970: 1120)
        )
    }
}
