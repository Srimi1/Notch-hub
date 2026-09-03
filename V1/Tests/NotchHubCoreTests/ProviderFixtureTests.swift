import Foundation
import Testing
@testable import NotchHubCore

@Suite("Provider fixture adapters")
struct ProviderFixtureTests {
    @Test("Fixture event sources finish deterministically")
    func eventSource() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let session = try AgentSession(
            id: "fixture-session",
            provider: .claude,
            projectName: "Fixture",
            status: .running,
            startedAt: timestamp,
            updatedAt: timestamp
        )
        let source = FixtureSessionEventSource(
            provider: .claude,
            events: [.upserted(session), .removed(provider: .claude, sessionID: session.id)]
        )

        var received: [SessionEvent] = []
        for try await event in source.makeEventStream() {
            received.append(event)
        }
        #expect(received == [.upserted(session), .removed(provider: .claude, sessionID: session.id)])
    }

    @Test("Fixture usage adapters expose bounded call counts")
    func usageAdapter() async throws {
        let quota = try QuotaWindow(id: "weekly", label: "Weekly", usedPercent: 5)
        let snapshot = try UsageSnapshot(provider: .codex, windows: [quota], capturedAt: .now)
        let adapter = FixtureUsageProviderAdapter(provider: .codex, results: [.success(snapshot)])

        #expect(try await adapter.fetchUsage() == snapshot)
        #expect(await adapter.fetchCount() == 1)

        do {
            _ = try await adapter.fetchUsage()
            Issue.record("Expected fixture exhaustion")
        } catch let error as ProviderError {
            #expect(error == .adapterUnavailable(provider: .codex))
        } catch {
            Issue.record("Unexpected error type")
        }
    }
}
