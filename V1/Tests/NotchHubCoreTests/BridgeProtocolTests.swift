import Foundation
import Testing
@testable import NotchHubCore

@Suite("Bridge protocol")
struct BridgeProtocolTests {
    @Test("Approval metadata round-trips without sensitive fields")
    func approvalRoundTrip() throws {
        let approval = try BridgeApprovalRequest(
            approvalID: "approval-1",
            provider: .codex,
            sessionID: "session-1",
            projectLabel: "/Users/example/NotchHub",
            actionCategory: .unknown,
            targetLabel: "alice@example.com token=top-secret build",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try BridgeRequestEnvelope(nonce: "nonce-123", event: .approval(approval))
        let encoded = try BridgeCodec.encodeRequest(request)
        let decoded = try BridgeCodec.decodeRequest(encoded)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(decoded == request)
        #expect(approval.projectLabel == "NotchHub")
        #expect(approval.targetLabel == "[redacted] [redacted] build")
        #expect(approval.risk == .high)
        #expect(!json.lowercased().contains("top-secret"))
        #expect(!json.lowercased().contains("alice@example.com"))
        #expect(!json.lowercased().contains("prompt"))
        #expect(!json.lowercased().contains("transcript"))
        #expect(!json.lowercased().contains("credential"))
    }

    @Test("Forbidden fields are rejected even when Codable would ignore them")
    func forbiddenFieldRejected() throws {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .claude,
            sessionID: "session-1",
            state: .running,
            projectLabel: "Project",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try BridgeRequestEnvelope(nonce: "nonce-123", event: .session(event))
        let encoded = try BridgeCodec.encodeRequest(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["accessToken"] = "do something private"
        let tainted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: BridgeProtocolError.forbiddenField("accessToken")) {
            try BridgeCodec.decodeRequest(tainted)
        }
    }

    @Test("Malformed and oversized messages are rejected")
    func inputBounds() {
        #expect(throws: BridgeProtocolError.malformedPayload) {
            try BridgeCodec.decodeRequest(Data("{".utf8))
        }
        #expect(throws: BridgeProtocolError.oversizedPayload(limit: 8)) {
            try BridgeCodec.decodeRequest(Data(repeating: 0x41, count: 9), maximumBytes: 8)
        }
    }

    @Test("Bounded file-handle reader stops above its limit")
    func boundedReader() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("12345".utf8))
        try pipe.fileHandleForWriting.close()

        #expect(throws: BridgeProtocolError.oversizedPayload(limit: 4)) {
            try BridgeBoundedInput.read(from: pipe.fileHandleForReading, maximumBytes: 4)
        }
        try pipe.fileHandleForReading.close()
    }

    @Test("Decoded values must already satisfy canonical sanitization")
    func decodedSanitizationIsEnforced() throws {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .codex,
            sessionID: "session-1",
            state: .running,
            projectLabel: "SafeProject",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let request = try BridgeRequestEnvelope(nonce: "nonce-123", event: .session(event))
        let encoded = try BridgeCodec.encodeRequest(request)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var eventObject = try #require(root["event"] as? [String: Any])
        var sessionObject = try #require(eventObject["session"] as? [String: Any])
        sessionObject["projectLabel"] = "/private/path/UnsafeProject"
        eventObject["session"] = sessionObject
        root["event"] = eventObject
        let data = try JSONSerialization.data(withJSONObject: root)

        #expect(throws: BridgeProtocolError.invalidIdentifier("session")) {
            try BridgeCodec.decodeRequest(data)
        }
    }
}
