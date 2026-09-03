import Foundation
import Security
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

private let claudeStatusLinePayload = Data(
    #"""
    {
      "session_id": "session-1",
      "cwd": "/private/project",
      "transcript_path": "/private/transcript.jsonl",
      "prompt": "private prompt",
      "rate_limits": {
        "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
        "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}
      },
      "context_window": {"total_input_tokens": 999}
    }
    """#.utf8
)

@Suite("Authenticated bridge transport")
struct BridgeTransportAuthenticationTests {
    private let secret = Data(repeating: 0xA5, count: 32)
    private let nonce = String(repeating: "a", count: 64)

    @Test("Keychain namespace is deterministic and rejects unsafe team identifiers")
    func keychainNamespace() throws {
        #expect(
            try BridgeKeychainNamespace.accessGroup(teamIdentifier: "ABCDE12345")
                == "ABCDE12345.com.notchhub.v1.bridge"
        )
        #expect(throws: BridgeTransportError.keychainSharingUnavailable(status: errSecParam)) {
            try BridgeKeychainNamespace.accessGroup(teamIdentifier: "BAD.TEAM")
        }
    }

    @Test("Request and response authentication rejects tampering")
    func authentication() throws {
        let request = try sampleRequest()
        let frame = try BridgeTransportAuthenticator.makeRequestFrame(
            request: request,
            nonce: nonce,
            issuedAtMilliseconds: 1_000,
            deadlineMilliseconds: 121_000,
            secret: secret
        )
        try BridgeTransportAuthenticator.verifyRequestFrame(frame, secret: secret)

        var tamperedTag = frame.authenticationTag
        tamperedTag[0] ^= 0x01
        let tampered = BridgeTransportRequestFrame(
            nonce: frame.nonce,
            issuedAtMilliseconds: frame.issuedAtMilliseconds,
            deadlineMilliseconds: frame.deadlineMilliseconds,
            request: frame.request,
            authenticationTag: tamperedTag
        )
        #expect(throws: BridgeTransportError.authenticationFailed) {
            try BridgeTransportAuthenticator.verifyRequestFrame(tampered, secret: secret)
        }

        let response = BridgeResponseEnvelope(nonce: request.nonce, verdict: .allowOnce, abstainReason: nil)
        let responseFrame = try BridgeTransportAuthenticator.makeResponseFrame(
            response: response,
            transportNonce: nonce,
            secret: secret
        )
        try BridgeTransportAuthenticator.verifyResponseFrame(responseFrame, secret: secret)
        #expect(
            !BridgeTransportAuthenticator.constantTimeEqual(
                responseFrame.authenticationTag,
                Data(repeating: 0, count: 32)
            )
        )
    }

    @Test("Replay guard enforces nonce freshness and a 120 second deadline")
    func replayAndDeadline() async throws {
        let guardActor = BridgeTransportReplayGuard()
        try await guardActor.validateAndRecord(
            nonce: nonce,
            issuedAtMilliseconds: 1_000,
            deadlineMilliseconds: 121_000,
            nowMilliseconds: 2_000
        )
        await #expect(throws: BridgeTransportError.replayDetected) {
            try await guardActor.validateAndRecord(
                nonce: nonce,
                issuedAtMilliseconds: 1_000,
                deadlineMilliseconds: 121_000,
                nowMilliseconds: 2_000
            )
        }
        await #expect(throws: BridgeTransportError.invalidDeadline) {
            try await guardActor.validateAndRecord(
                nonce: String(repeating: "b", count: 64),
                issuedAtMilliseconds: 1_000,
                deadlineMilliseconds: 121_001,
                nowMilliseconds: 2_000
            )
        }
        await #expect(throws: BridgeTransportError.deadlineExceeded) {
            try await guardActor.validateAndRecord(
                nonce: String(repeating: "c", count: 64),
                issuedAtMilliseconds: 1_000,
                deadlineMilliseconds: 2_000,
                nowMilliseconds: 2_001
            )
        }
    }

    @Test("Framing rejects oversized lengths, truncation, and trailing bytes")
    func framingBounds() throws {
        let request = try sampleRequest()
        let frame = try BridgeTransportAuthenticator.makeRequestFrame(
            request: request,
            nonce: nonce,
            issuedAtMilliseconds: 1_000,
            deadlineMilliseconds: 2_000,
            secret: secret
        )
        let framed = try BridgeTransportFraming.framedData(for: frame)
        let decoded = try BridgeTransportFraming.decodedValue(
            BridgeTransportRequestFrame.self,
            fromFramedData: framed
        )
        #expect(decoded == frame)
        #expect(throws: BridgeTransportError.malformedFrame) {
            try BridgeTransportFraming.decodedValue(
                BridgeTransportRequestFrame.self,
                fromFramedData: Data(framed.dropLast())
            )
        }
        #expect(throws: BridgeTransportError.trailingFrameData) {
            try BridgeTransportFraming.decodedValue(
                BridgeTransportRequestFrame.self,
                fromFramedData: framed + Data([0])
            )
        }
        let oversizedPrefix = Data([0x00, 0x02, 0x00, 0x01])
        #expect(throws: BridgeTransportError.oversizedFrame(limit: BridgeTransportConstants.maximumFrameBytes)) {
            try BridgeTransportFraming.decodedValue(
                BridgeTransportRequestFrame.self,
                fromFramedData: oversizedPrefix
            )
        }
    }

    @Test("Transport decoding rejects sensitive fields hidden beside the signed request")
    func sensitiveTransportField() throws {
        let request = try sampleRequest()
        let frame = try BridgeTransportAuthenticator.makeRequestFrame(
            request: request,
            nonce: nonce,
            issuedAtMilliseconds: 1_000,
            deadlineMilliseconds: 2_000,
            secret: secret
        )
        let body = try BridgeTransportFraming.encodedBody(
            frame,
            maximumBytes: BridgeTransportConstants.maximumFrameBytes
        )
        var root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var requestObject = try #require(root["request"] as? [String: Any])
        requestObject["prompt"] = "private prompt"
        root["request"] = requestObject
        let tainted = try JSONSerialization.data(withJSONObject: root)

        #expect(throws: BridgeProtocolError.forbiddenField("prompt")) {
            try BridgeTransportFraming.decodedRequestBody(tainted)
        }
    }
}

extension BridgeTransportAuthenticationTests {
    @Test("Provider input is reduced to safe metadata and output is official decision JSON")
    func providerTranslation() throws {
        let invocation = try BridgeHookInvocation(
            provider: .codex,
            event: .permissionRequest,
            hookID: "com.notchhub.v1.codex.permissionrequest"
        )
        let raw = Data(
            #"""
            {
              "session_id": "session-1",
              "hook_event_name": "PermissionRequest",
              "cwd": "/private/NotchHub",
              "tool_name": "Bash",
              "tool_input": {"command": "echo top-secret"},
              "transcript_path": "/private/transcript.jsonl"
            }
            """#.utf8
        )
        let request = try BridgeProviderHookCodec.request(
            from: raw,
            invocation: invocation,
            now: Date(timeIntervalSince1970: 1_000),
            requestNonce: nonce
        )
        let encoded = try BridgeCodec.encodeRequest(request)
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!text.contains("top-secret"))
        #expect(!text.contains("transcript"))
        #expect(text.contains("processExecution"))

        let response = BridgeResponseEnvelope(nonce: nonce, verdict: .allowOnce, abstainReason: nil)
        let optionalOutput = try BridgeProviderHookCodec.providerOutput(for: response, invocation: invocation)
        let output = try #require(optionalOutput)
        let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "allow")
    }

    @Test("Abstain and lifecycle hooks emit no provider output")
    func silentOutputs() throws {
        let permission = try BridgeHookInvocation(
            provider: .claude,
            event: .permissionRequest,
            hookID: "com.notchhub.v1.claude.permissionrequest"
        )
        let lifecycle = try BridgeHookInvocation(
            provider: .codex,
            event: .sessionEnd,
            hookID: "com.notchhub.v1.codex.sessionend"
        )
        let stop = try BridgeHookInvocation(
            provider: .codex,
            event: .stop,
            hookID: "com.notchhub.v1.codex.stop"
        )
        let abstain = BridgeResponseEnvelope.abstaining(nonce: nonce, reason: .unavailable)
        let allow = BridgeResponseEnvelope(nonce: nonce, verdict: .allowOnce, abstainReason: nil)
        let stopRequest = try BridgeProviderHookCodec.request(
            from: Data(#"{"session_id":"session-1","hook_event_name":"Stop"}"#.utf8),
            invocation: stop,
            now: Date(timeIntervalSince1970: 1_000),
            requestNonce: nonce
        )

        #expect(try BridgeProviderHookCodec.providerOutput(for: abstain, invocation: permission) == nil)
        #expect(try BridgeProviderHookCodec.providerOutput(for: allow, invocation: lifecycle) == nil)
        #expect(try BridgeProviderHookCodec.providerOutput(for: allow, invocation: stop) == Data("{}".utf8))
        if case let .session(event) = stopRequest.event {
            #expect(event.state == .running)
        } else {
            Issue.record("Codex Stop did not produce a session event")
        }
    }

    @Test("Claude status line forwards only bounded rate-limit fields")
    func claudeStatusLineTranslation() throws {
        let invocation = try BridgeHookInvocation(
            provider: .claude,
            event: .statusLine,
            hookID: "com.notchhub.v1.claude.statusline"
        )
        let request = try BridgeProviderHookCodec.request(
            from: claudeStatusLinePayload,
            invocation: invocation,
            now: Date(timeIntervalSince1970: 1_000),
            requestNonce: nonce
        )
        let encoded = try BridgeCodec.encodeRequest(request)
        let text = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(text.contains("fiveHour"))
        #expect(text.contains("sevenDay"))
        #expect(text.contains("23.5"))
        #expect(!text.contains("private prompt"))
        #expect(!text.contains("transcript"))
        #expect(!text.contains("999"))

        let response = BridgeResponseEnvelope(nonce: nonce, verdict: .allowOnce, abstainReason: nil)
        let statusOutput = try BridgeProviderHookCodec.providerOutput(
            for: response,
            request: request,
            invocation: invocation
        )
        #expect(statusOutput == Data("NotchHub · 5h 24% · 7d 41%".utf8))
    }

    @Test("Invalid Claude status-line percentages are rejected")
    func invalidClaudeStatusLine() throws {
        let invocation = try BridgeHookInvocation(
            provider: .claude,
            event: .statusLine,
            hookID: "com.notchhub.v1.claude.statusline"
        )
        let raw = Data(
            #"""
            {
              "session_id": "session-1",
              "rate_limits": {
                "five_hour": {"used_percentage": 101, "resets_at": 1738425600}
              }
            }
            """#.utf8
        )
        #expect(throws: BridgeProviderHookError.malformedInput) {
            try BridgeProviderHookCodec.request(
                from: raw,
                invocation: invocation,
                now: Date(timeIntervalSince1970: 1_000),
                requestNonce: nonce
            )
        }
        #expect(throws: BridgeProviderHookError.invalidArguments) {
            try BridgeHookInvocation(
                provider: .codex,
                event: .statusLine,
                hookID: "com.notchhub.v1.codex.statusline"
            )
        }
    }

    private func sampleRequest() throws -> BridgeRequestEnvelope {
        let event = try BridgeSessionEvent(
            eventID: "event-1",
            provider: .codex,
            sessionID: "session-1",
            state: .running,
            projectLabel: "NotchHub",
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )
        return try BridgeRequestEnvelope(nonce: nonce, event: .session(event))
    }
}
