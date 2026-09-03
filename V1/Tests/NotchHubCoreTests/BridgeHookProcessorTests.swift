import Foundation
import Testing
@testable import NotchHubCore

@Suite("Bridge hook fail-open behavior")
struct BridgeHookProcessorTests {
    private let processor = BridgeHookProcessor()

    @Test("Valid requests abstain until a trusted responder exists")
    func validRequestAbstains() throws {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .codex,
            sessionID: "session-1",
            state: .waitingForApproval,
            projectLabel: "NotchHub",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try BridgeRequestEnvelope(nonce: "nonce-123", event: .session(event))
        let response = try processor.response(for: BridgeCodec.encodeRequest(request))

        #expect(response.verdict == .abstain)
        #expect(response.abstainReason == .awaitingTrustedResponder)
        #expect(response.nonce == "nonce-123")
    }

    @Test("Malformed, unavailable, and timeout paths never allow")
    func failurePathsAbstain() {
        let malformed = processor.response(for: Data("not-json".utf8))
        let unavailable = processor.unavailableResponse(nonce: "nonce-123")
        let timedOut = processor.timeoutResponse(nonce: "nonce-123")

        #expect(malformed.verdict == .abstain)
        #expect(malformed.abstainReason == .invalidInput)
        #expect(unavailable.verdict == .abstain)
        #expect(unavailable.abstainReason == .unavailable)
        #expect(timedOut.verdict == .abstain)
        #expect(timedOut.abstainReason == .timedOut)
        #expect([malformed, unavailable, timedOut].allSatisfy { $0.verdict != .allowOnce })
    }

    @Test("Unsupported versions abstain without reflecting attacker input")
    func unsupportedVersionAbstains() throws {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .claude,
            sessionID: "session-1",
            state: .running,
            projectLabel: nil,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try BridgeRequestEnvelope(version: 999, nonce: "nonce-123", event: .session(event))
        let response = try processor.response(for: BridgeCodec.encodeRequest(request))

        #expect(response.verdict == .abstain)
        #expect(response.abstainReason == .unsupportedVersion)
        #expect(response.nonce == "invalid")
    }
}
