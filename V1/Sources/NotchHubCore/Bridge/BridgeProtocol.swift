import Foundation

public enum BridgeProtocolConstants {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 64 * 1024
    public static let maximumNonceLength = 128
    public static let maximumIdentifierLength = 128
    public static let maximumLabelLength = 160
}

public enum BridgeLifecycleState: String, Codable, CaseIterable, Sendable {
    case started
    case running
    case waitingForApproval
    case completed
    case failed
    case interrupted
    case ended
}

public enum BridgeActionCategory: String, Codable, CaseIterable, Sendable {
    case fileRead
    case fileWrite
    case processExecution
    case networkAccess
    case versionControl
    case systemChange
    case unknown
}

public enum BridgeRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case elevated
    case high

    public static func conservativeLevel(for category: BridgeActionCategory) -> Self {
        switch category {
        case .fileRead, .versionControl:
            .elevated
        case .fileWrite, .processExecution, .networkAccess, .systemChange, .unknown:
            .high
        }
    }
}

public struct BridgeSessionEvent: Codable, Equatable, Sendable {
    public let eventID: String
    public let provider: ProviderID
    public let sessionID: String
    public let state: BridgeLifecycleState
    public let projectLabel: String?
    public let occurredAt: Date

    public init(
        eventID: String,
        provider: ProviderID,
        sessionID: String,
        state: BridgeLifecycleState,
        projectLabel: String?,
        occurredAt: Date
    ) throws {
        self.eventID = try BridgeSanitizer.identifier(eventID, field: "eventID")
        self.provider = provider
        self.sessionID = try BridgeSanitizer.identifier(sessionID, field: "sessionID")
        self.state = state
        self.projectLabel = BridgeSanitizer.optionalProjectLabel(projectLabel)
        self.occurredAt = occurredAt
    }
}

public struct BridgeApprovalRequest: Codable, Equatable, Sendable {
    public let approvalID: String
    public let provider: ProviderID
    public let sessionID: String
    public let projectLabel: String?
    public let actionCategory: BridgeActionCategory
    public let targetLabel: String?
    public let risk: BridgeRiskLevel
    public let expiresAt: Date

    public init(
        approvalID: String,
        provider: ProviderID,
        sessionID: String,
        projectLabel: String?,
        actionCategory: BridgeActionCategory,
        targetLabel: String?,
        expiresAt: Date
    ) throws {
        self.approvalID = try BridgeSanitizer.identifier(approvalID, field: "approvalID")
        self.provider = provider
        self.sessionID = try BridgeSanitizer.identifier(sessionID, field: "sessionID")
        self.projectLabel = BridgeSanitizer.optionalProjectLabel(projectLabel)
        self.actionCategory = actionCategory
        self.targetLabel = BridgeSanitizer.optionalLabel(targetLabel)
        self.risk = BridgeRiskLevel.conservativeLevel(for: actionCategory)
        self.expiresAt = expiresAt
    }
}

public enum BridgeRateLimitWindowID: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case sevenDay
}

public struct BridgeRateLimitWindow: Codable, Equatable, Sendable {
    public let id: BridgeRateLimitWindowID
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: BridgeRateLimitWindowID, usedPercent: Double, resetsAt: Date?) throws {
        guard usedPercent.isFinite, (0 ... 100).contains(usedPercent) else {
            throw BridgeProtocolError.invalidRateLimit
        }
        self.id = id
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, usedPercent, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(BridgeRateLimitWindowID.self, forKey: .id),
            usedPercent: values.decode(Double.self, forKey: .usedPercent),
            resetsAt: values.decodeIfPresent(Date.self, forKey: .resetsAt)
        )
    }
}

public struct BridgeStatusLineEvent: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let sessionID: String
    public let rateLimits: [BridgeRateLimitWindow]
    public let capturedAt: Date

    public init(
        provider: ProviderID,
        sessionID: String,
        rateLimits: [BridgeRateLimitWindow],
        capturedAt: Date
    ) throws {
        guard provider == .claude,
              rateLimits.count <= BridgeRateLimitWindowID.allCases.count,
              Set(rateLimits.map(\.id)).count == rateLimits.count
        else {
            throw BridgeProtocolError.invalidRateLimit
        }
        self.provider = provider
        self.sessionID = try BridgeSanitizer.identifier(sessionID, field: "sessionID")
        self.rateLimits = rateLimits
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case provider, sessionID, rateLimits, capturedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: values.decode(ProviderID.self, forKey: .provider),
            sessionID: values.decode(String.self, forKey: .sessionID),
            rateLimits: values.decode([BridgeRateLimitWindow].self, forKey: .rateLimits),
            capturedAt: values.decode(Date.self, forKey: .capturedAt)
        )
    }
}

public enum BridgeEvent: Codable, Equatable, Sendable {
    case session(BridgeSessionEvent)
    case approval(BridgeApprovalRequest)
    case statusLine(BridgeStatusLineEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case approval
        case statusLine
    }

    private enum EventType: String, Codable {
        case session
        case approval
        case statusLine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .session:
            self = try .session(container.decode(BridgeSessionEvent.self, forKey: .session))
        case .approval:
            self = try .approval(container.decode(BridgeApprovalRequest.self, forKey: .approval))
        case .statusLine:
            self = try .statusLine(container.decode(BridgeStatusLineEvent.self, forKey: .statusLine))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .session(event):
            try container.encode(EventType.session, forKey: .type)
            try container.encode(event, forKey: .session)
        case let .approval(request):
            try container.encode(EventType.approval, forKey: .type)
            try container.encode(request, forKey: .approval)
        case let .statusLine(event):
            try container.encode(EventType.statusLine, forKey: .type)
            try container.encode(event, forKey: .statusLine)
        }
    }
}

public struct BridgeRequestEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let event: BridgeEvent

    public init(version: Int = BridgeProtocolConstants.currentVersion, nonce: String, event: BridgeEvent) throws {
        self.version = version
        self.nonce = try BridgeSanitizer.nonce(nonce)
        self.event = event
    }
}

public enum BridgeApprovalVerdict: String, Codable, CaseIterable, Sendable {
    case allowOnce
    case deny
    case abstain
}

public enum BridgeAbstainReason: String, Codable, CaseIterable, Sendable {
    case awaitingTrustedResponder
    case invalidInput
    case unsupportedVersion
    case unavailable
    case timedOut
    case authenticationFailed
}

public struct BridgeResponseEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let verdict: BridgeApprovalVerdict
    public let abstainReason: BridgeAbstainReason?

    public init(
        version: Int = BridgeProtocolConstants.currentVersion,
        nonce: String,
        verdict: BridgeApprovalVerdict,
        abstainReason: BridgeAbstainReason?
    ) {
        self.version = version
        self.nonce = nonce
        self.verdict = verdict
        self.abstainReason = abstainReason
    }

    public static func abstaining(nonce: String, reason: BridgeAbstainReason) -> Self {
        Self(nonce: nonce, verdict: .abstain, abstainReason: reason)
    }
}

public enum BridgeProtocolError: Error, Equatable, Sendable {
    case emptyPayload
    case oversizedPayload(limit: Int)
    case malformedPayload
    case unsupportedVersion(Int)
    case forbiddenField(String)
    case invalidIdentifier(String)
    case invalidNonce
    case invalidRateLimit
}

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
