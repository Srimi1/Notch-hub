import Foundation
import Testing
@testable import NotchHubCore

@Suite("Official provider adapter payloads")
struct IntegrationAdapterTests {
    @Test("Codex multi-bucket response becomes provider-neutral windows")
    func codexRateLimits() throws {
        let response = Data(
            #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"9.5"},"planType":"pro"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1800100000},"credits":{"hasCredits":true,"unlimited":false,"balance":"9.5"},"planType":"pro"},"spark":{"limitId":"spark","limitName":"Spark","primary":{"usedPercent":3,"windowDurationMins":60,"resetsAt":1800000100},"secondary":null,"credits":null,"planType":"pro"}}}}"#.utf8
        )
        let capturedAt = Date(timeIntervalSince1970: 1_799_999_000)

        let snapshot = try CodexRateLimitDecoder.snapshot(from: response, capturedAt: capturedAt)

        #expect(snapshot.provider == .codex)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.highestUsedPercent == 41)
        #expect(snapshot.planName == "pro")
        #expect(snapshot.creditsRemaining == 9.5)
        #expect(snapshot.capturedAt == capturedAt)
    }

    @Test("Codex authentication failures become a typed signed-out state")
    func codexSignedOut() {
        let response = Data(#"{"id":2,"error":{"code":401,"message":"authentication required"}}"#.utf8)
        #expect(throws: ProviderError.signedOut(provider: .codex)) {
            try CodexRateLimitDecoder.snapshot(from: response, capturedAt: .now)
        }
    }

    @Test("Malformed Codex output is rejected without retaining it")
    func codexMalformed() {
        #expect(throws: ProviderError.malformedResponse(provider: .codex)) {
            try CodexRateLimitDecoder.snapshot(from: Data("not-json".utf8), capturedAt: .now)
        }
    }

    @Test("Claude status-line rate limits become a snapshot")
    func claudeRateLimits() async throws {
        let adapter = ClaudeStatusLineUsageAdapter()
        let payload = Data(
            #"{"session_id":"ignored","transcript_path":"ignored","rate_limits":{"five_hour":{"used_percentage":22.5,"resets_at":1800000000},"seven_day":{"used_percentage":67,"resets_at":1800100000}}}"#.utf8
        )
        let capturedAt = Date(timeIntervalSince1970: 1_799_999_000)

        try await adapter.ingest(payload, capturedAt: capturedAt)
        let snapshot = try await adapter.fetchUsage()

        #expect(snapshot.provider == .claude)
        #expect(snapshot.windows.map(\.usedPercent) == [22.5, 67])
        #expect(snapshot.capturedAt == capturedAt)
    }

    @Test("Claude payloads without rate-limit data remain unavailable")
    func claudeUnavailable() async {
        let adapter = ClaudeStatusLineUsageAdapter()
        await #expect(throws: ProviderError.adapterUnavailable(provider: .claude)) {
            try await adapter.ingest(Data(#"{"session_id":"safe"}"#.utf8))
        }
    }

    @Test("Provider environment excludes inherited credentials")
    func minimalEnvironment() {
        let environment = CodexEnvironment.minimumInherited(from: [
            "HOME": "/Users/tester",
            "CODEX_HOME": "/Users/tester/.codex-alt",
            "OPENAI_API_KEY": "must-not-pass",
            "PATH": "/untrusted/bin",
        ])

        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["CODEX_HOME"] == "/Users/tester/.codex-alt")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("Only the validated CLI directory is added for env shebang launchers")
    func executableDirectoryEnvironment() {
        let environment = CodexEnvironment.addingExecutableDirectory(
            to: ["PATH": "/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/Users/tester/.nvm/versions/node/v24/bin/codex")
        )

        #expect(environment["PATH"] == "/Users/tester/.nvm/versions/node/v24/bin:/usr/bin:/bin")
    }
}
