import Foundation
import Testing
@testable import NotchHubCore

@Suite("Local telemetry console")
struct TelemetryTests {
    @Test("Sensitive values are removed before storage")
    func redaction() async throws {
        let console = LocalTelemetryConsole(capacity: 5)
        await console.record(
            severity: .error,
            category: "provider/codex",
            code: "signed out!",
            summary: "user@example.com failed at /Users/alice/Secret with Bearer abcdefghijklmno"
        )

        let entries = await console.snapshot()
        let entry = try #require(entries.first)
        #expect(entry.category == "providercodex")
        #expect(entry.code == "signedout")
        #expect(!entry.summary.contains("user@example.com"))
        #expect(!entry.summary.contains("alice"))
        #expect(!entry.summary.contains("abcdefghijklmno"))
        #expect(entry.summary.contains("<redacted-email>"))
        #expect(entry.summary.contains("<redacted-secret>"))
    }

    @Test("Ring buffer remains bounded")
    func boundedCapacity() async {
        let console = LocalTelemetryConsole(capacity: 2)
        await console.record(severity: .info, category: "test", code: "one", summary: "one")
        await console.record(severity: .info, category: "test", code: "two", summary: "two")
        await console.record(severity: .info, category: "test", code: "three", summary: "three")

        let entries = await console.snapshot()
        #expect(entries.map(\.code) == ["two", "three"])
    }

    @Test("Export contains only redacted entries")
    func export() async throws {
        let console = LocalTelemetryConsole(capacity: 2)
        let fakeSecret = ["sk", String(repeating: "x", count: 26)].joined(separator: "-")
        await console.record(
            severity: .warning,
            category: "bridge",
            code: "auth",
            summary: fakeSecret
        )
        let data = try await console.exportJSON()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(fakeSecret))
        #expect(text.contains("redacted-secret"))
    }
}
