import Foundation

public enum BridgeTransportConstants {
    public static let currentVersion = 1
    public static let maximumFrameBytes = BridgeProtocolConstants.maximumPayloadBytes
    public static let maximumDeadlineMilliseconds: Int64 = 120_000
    public static let maximumFutureSkewMilliseconds: Int64 = 30_000
    public static let minimumSecretBytes = 32
    public static let nonceBytes = 32
    public static let maximumConcurrentConnections = 16
}

public struct BridgeTransportRequestFrame: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let issuedAtMilliseconds: Int64
    public let deadlineMilliseconds: Int64
    public let request: BridgeRequestEnvelope
    public let authenticationTag: Data

    public init(
        version: Int = BridgeTransportConstants.currentVersion,
        nonce: String,
        issuedAtMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        request: BridgeRequestEnvelope,
        authenticationTag: Data
    ) {
        self.version = version
        self.nonce = nonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.deadlineMilliseconds = deadlineMilliseconds
        self.request = request
        self.authenticationTag = authenticationTag
    }
}

public struct BridgeTransportResponseFrame: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let response: BridgeResponseEnvelope
    public let authenticationTag: Data

    public init(
        version: Int = BridgeTransportConstants.currentVersion,
        nonce: String,
        response: BridgeResponseEnvelope,
        authenticationTag: Data
    ) {
        self.version = version
        self.nonce = nonce
        self.response = response
        self.authenticationTag = authenticationTag
    }
}

public enum BridgeTrustedDecision: Equatable, Sendable {
    case allowOnce
    case deny
    case abstain(BridgeAbstainReason)

    func response(nonce: String) -> BridgeResponseEnvelope {
        switch self {
        case .allowOnce:
            BridgeResponseEnvelope(nonce: nonce, verdict: .allowOnce, abstainReason: nil)
        case .deny:
            BridgeResponseEnvelope(nonce: nonce, verdict: .deny, abstainReason: nil)
        case let .abstain(reason):
            .abstaining(nonce: nonce, reason: reason)
        }
    }
}

public enum BridgeTransportError: Error, Equatable, Sendable {
    case invalidSecret
    case keychainInteractionRequired
    case keychainSharingUnavailable(status: Int32)
    case invalidNonce
    case invalidDeadline
    case deadlineExceeded
    case cancelled
    case connectionLimitExceeded(limit: Int)
    case unsupportedVersion(Int)
    case authenticationFailed
    case replayDetected
    case oversizedFrame(limit: Int)
    case malformedFrame
    case trailingFrameData
    case invalidSocketPath
    case socketPathConflict
    case insecureSocketPermissions
    case peerIdentityMismatch
    case unavailable
    case alreadyRunning
    case notRunning
    case posix(operation: String, code: Int32)
}

public protocol BridgeTransportClock: Sendable {
    func nowMilliseconds() -> Int64
}

public struct SystemBridgeTransportClock: BridgeTransportClock {
    public init() {}

    public func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public protocol BridgeNonceGenerating: Sendable {
    func freshNonce() throws -> String
}

public protocol BridgeSecretProviding: Sendable {
    func loadSecret() throws -> Data
}

public protocol BridgePeerVerifying: Sendable {
    func verifyPeer(socketDescriptor: Int32) throws
}
