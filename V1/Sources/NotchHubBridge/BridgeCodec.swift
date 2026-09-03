import Foundation

public enum BridgeCodec {
    private static let forbiddenKeyFragments = [
        "apikey", "argument", "argv", "authorization", "command", "credential", "input", "output", "password",
        "prompt", "secret", "stderr", "stdout", "token", "transcript",
    ]

    public static func decodeRequest(
        _ data: Data,
        maximumBytes: Int = BridgeProtocolConstants.maximumPayloadBytes
    ) throws -> BridgeRequestEnvelope {
        guard !data.isEmpty else {
            throw BridgeProtocolError.emptyPayload
        }
        guard data.count <= maximumBytes else {
            throw BridgeProtocolError.oversizedPayload(limit: maximumBytes)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BridgeProtocolError.malformedPayload
        }

        if let forbiddenKey = firstForbiddenKey(in: object) {
            throw BridgeProtocolError.forbiddenField(forbiddenKey)
        }

        let envelope: BridgeRequestEnvelope
        do {
            envelope = try decoder.decode(BridgeRequestEnvelope.self, from: data)
        } catch let error as BridgeProtocolError {
            throw error
        } catch {
            throw BridgeProtocolError.malformedPayload
        }

        guard envelope.version == BridgeProtocolConstants.currentVersion else {
            throw BridgeProtocolError.unsupportedVersion(envelope.version)
        }
        try validate(envelope)
        return envelope
    }

    public static func encodeResponse(_ response: BridgeResponseEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }

    public static func encodeRequest(_ request: BridgeRequestEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func firstForbiddenKey(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if isForbiddenKey(key) {
                    return key
                }
                guard let child = dictionary[key] else {
                    continue
                }
                if let nestedKey = firstForbiddenKey(in: child) {
                    return nestedKey
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nestedKey = firstForbiddenKey(in: child) {
                    return nestedKey
                }
            }
        }
        return nil
    }

    private static func isForbiddenKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return forbiddenKeyFragments.contains(where: normalized.contains)
    }

    private static func validate(_ envelope: BridgeRequestEnvelope) throws {
        let validatedNonce = try BridgeSanitizer.nonce(envelope.nonce)
        guard validatedNonce == envelope.nonce else {
            throw BridgeProtocolError.invalidNonce
        }

        switch envelope.event {
        case let .session(event):
            let eventID = try BridgeSanitizer.identifier(event.eventID, field: "eventID")
            let sessionID = try BridgeSanitizer.identifier(event.sessionID, field: "sessionID")
            guard eventID == event.eventID,
                  sessionID == event.sessionID,
                  event.projectLabel == BridgeSanitizer.optionalProjectLabel(event.projectLabel)
            else {
                throw BridgeProtocolError.invalidIdentifier("session")
            }
        case let .approval(request):
            let approvalID = try BridgeSanitizer.identifier(request.approvalID, field: "approvalID")
            let sessionID = try BridgeSanitizer.identifier(request.sessionID, field: "sessionID")
            guard approvalID == request.approvalID,
                  sessionID == request.sessionID,
                  request.projectLabel == BridgeSanitizer.optionalProjectLabel(request.projectLabel),
                  request.targetLabel == BridgeSanitizer.optionalLabel(request.targetLabel),
                  request.risk == BridgeRiskLevel.conservativeLevel(for: request.actionCategory)
            else {
                throw BridgeProtocolError.invalidIdentifier("approval")
            }
        case let .statusLine(event):
            let sessionID = try BridgeSanitizer.identifier(event.sessionID, field: "sessionID")
            guard event.provider == .claude,
                  sessionID == event.sessionID,
                  event.rateLimits.count <= BridgeRateLimitWindowID.allCases.count,
                  Set(event.rateLimits.map(\.id)).count == event.rateLimits.count,
                  event.rateLimits.allSatisfy({ $0.usedPercent.isFinite && (0 ... 100).contains($0.usedPercent) })
            else {
                throw BridgeProtocolError.invalidRateLimit
            }
        }
    }
}
