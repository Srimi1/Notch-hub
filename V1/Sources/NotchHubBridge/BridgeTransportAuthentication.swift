import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

public struct SecureBridgeNonceGenerator: BridgeNonceGenerating {
    public init() {}

    public func freshNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: BridgeTransportConstants.nonceBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BridgeTransportError.posix(operation: "secure random", code: status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct InMemoryBridgeSecretProvider: BridgeSecretProviding {
    private let value: Data

    public init(secret: Data) {
        value = secret
    }

    public func loadSecret() throws -> Data {
        value
    }
}

public struct KeychainBridgeSecretProvider: BridgeSecretProviding {
    public static let defaultService = "com.notchhub.v1.bridge"
    public static let defaultAccount = "transport-hmac-v1"

    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadSecret() throws -> Data {
        let resolvedGroup = try BridgeKeychainNamespace.resolvedAccessGroup(explicit: accessGroup)
        return try KeychainBridgeSecretAccess.load(
            service: service,
            account: account,
            accessGroup: resolvedGroup
        )
    }
}

/// App-side provider that creates the per-install secret if it does not exist.
/// Hook helpers intentionally use ``KeychainBridgeSecretProvider`` instead.
public struct KeychainBridgeSecretStore: BridgeSecretProviding {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = KeychainBridgeSecretProvider.defaultService,
        account: String = KeychainBridgeSecretProvider.defaultAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadSecret() throws -> Data {
        let resolvedGroup = try BridgeKeychainNamespace.resolvedAccessGroup(explicit: accessGroup)
        do {
            return try KeychainBridgeSecretAccess.load(
                service: service,
                account: account,
                accessGroup: resolvedGroup
            )
        } catch BridgeTransportError.unavailable {
            return try KeychainBridgeSecretAccess.createOrLoad(
                service: service,
                account: account,
                accessGroup: resolvedGroup
            )
        }
    }
}

public enum BridgeKeychainNamespace {
    public static let accessGroupSuffix = "com.notchhub.v1.bridge"

    public static func accessGroup(teamIdentifier: String) throws -> String {
        let allowed = CharacterSet.alphanumerics
        guard !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw BridgeTransportError.keychainSharingUnavailable(status: errSecParam)
        }
        return "\(teamIdentifier).\(accessGroupSuffix)"
    }

    static func resolvedAccessGroup(explicit: String?) throws -> String {
        if let explicit {
            let suffix = ".\(accessGroupSuffix)"
            guard explicit.hasSuffix(suffix), explicit.count > suffix.count else {
                throw BridgeTransportError.keychainSharingUnavailable(status: errSecParam)
            }
            return explicit
        }
        guard let executableURL = Bundle.main.executableURL else {
            throw BridgeTransportError.keychainSharingUnavailable(status: errSecParam)
        }
        var code: SecStaticCode?
        let selfStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code)
        guard selfStatus == errSecSuccess, let code else {
            throw BridgeTransportError.keychainSharingUnavailable(status: selfStatus)
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let values = information as? [String: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            throw BridgeTransportError.keychainSharingUnavailable(status: errSecMissingEntitlement)
        }
        return try accessGroup(teamIdentifier: teamIdentifier)
    }
}

private enum KeychainBridgeSecretAccess {
    static func load(service: String, account: String, accessGroup: String) throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup).merging([
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw BridgeTransportError.unavailable
            }
            throw mappedError(status: status)
        }
        guard let secret = result as? Data,
              secret.count >= BridgeTransportConstants.minimumSecretBytes
        else {
            throw BridgeTransportError.invalidSecret
        }
        return secret
    }

    static func createOrLoad(service: String, account: String, accessGroup: String) throws -> Data {
        let secret = try randomSecret()
        let attributes = baseQuery(service: service, account: account, accessGroup: accessGroup).merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: secret,
        ]) { _, new in new }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return secret
        case errSecDuplicateItem:
            return try load(service: service, account: account, accessGroup: accessGroup)
        default:
            throw mappedError(status: status)
        }
    }

    private static func baseQuery(service: String, account: String, accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    private static func randomSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: BridgeTransportConstants.minimumSecretBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BridgeTransportError.posix(operation: "keychain secret random", code: status)
        }
        return Data(bytes)
    }

    private static func mappedError(status: OSStatus) -> BridgeTransportError {
        if status == errSecInteractionNotAllowed {
            return .keychainInteractionRequired
        }
        return .keychainSharingUnavailable(status: status)
    }
}

public struct DarwinBridgePeerVerifier: BridgePeerVerifying {
    private let expectedUserID: uid_t

    public init(expectedUserID: uid_t = getuid()) {
        self.expectedUserID = expectedUserID
    }

    public func verifyPeer(socketDescriptor: Int32) throws {
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard getpeereid(socketDescriptor, &peerUserID, &peerGroupID) == 0 else {
            throw BridgeTransportError.posix(operation: "getpeereid", code: errno)
        }
        guard peerUserID == expectedUserID else {
            throw BridgeTransportError.peerIdentityMismatch
        }
    }
}

public enum BridgeTransportAuthenticator {
    public static func makeRequestFrame(
        request: BridgeRequestEnvelope,
        nonce: String,
        issuedAtMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        secret: Data
    ) throws -> BridgeTransportRequestFrame {
        try validateSecret(secret)
        let unsigned = BridgeTransportRequestFrame(
            nonce: nonce,
            issuedAtMilliseconds: issuedAtMilliseconds,
            deadlineMilliseconds: deadlineMilliseconds,
            request: request,
            authenticationTag: Data()
        )
        let tag = authenticate(data: try requestAuthenticationData(unsigned), secret: secret)
        return BridgeTransportRequestFrame(
            nonce: nonce,
            issuedAtMilliseconds: issuedAtMilliseconds,
            deadlineMilliseconds: deadlineMilliseconds,
            request: request,
            authenticationTag: tag
        )
    }

    public static func verifyRequestFrame(
        _ frame: BridgeTransportRequestFrame,
        secret: Data
    ) throws {
        try validateSecret(secret)
        guard frame.version == BridgeTransportConstants.currentVersion else {
            throw BridgeTransportError.unsupportedVersion(frame.version)
        }
        let expected = authenticate(data: try requestAuthenticationData(frame), secret: secret)
        guard constantTimeEqual(expected, frame.authenticationTag) else {
            throw BridgeTransportError.authenticationFailed
        }
    }

    public static func makeResponseFrame(
        response: BridgeResponseEnvelope,
        transportNonce: String,
        secret: Data
    ) throws -> BridgeTransportResponseFrame {
        try validateSecret(secret)
        let unsigned = BridgeTransportResponseFrame(
            nonce: transportNonce,
            response: response,
            authenticationTag: Data()
        )
        let tag = authenticate(data: try responseAuthenticationData(unsigned), secret: secret)
        return BridgeTransportResponseFrame(nonce: transportNonce, response: response, authenticationTag: tag)
    }

    public static func verifyResponseFrame(
        _ frame: BridgeTransportResponseFrame,
        secret: Data
    ) throws {
        try validateSecret(secret)
        guard frame.version == BridgeTransportConstants.currentVersion else {
            throw BridgeTransportError.unsupportedVersion(frame.version)
        }
        let expected = authenticate(data: try responseAuthenticationData(frame), secret: secret)
        guard constantTimeEqual(expected, frame.authenticationTag) else {
            throw BridgeTransportError.authenticationFailed
        }
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        lhs.withUnsafeBytes { (lhsBytes: UnsafeRawBufferPointer) in
            rhs.withUnsafeBytes { (rhsBytes: UnsafeRawBufferPointer) in
                for index in 0 ..< lhs.count {
                    difference |= lhsBytes[index] ^ rhsBytes[index]
                }
            }
        }
        return difference == 0
    }

    private static func validateSecret(_ secret: Data) throws {
        guard secret.count >= BridgeTransportConstants.minimumSecretBytes else {
            throw BridgeTransportError.invalidSecret
        }
    }

    private static func authenticate(data: Data, secret: Data) -> Data {
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func requestAuthenticationData(_ frame: BridgeTransportRequestFrame) throws -> Data {
        struct UnsignedRequest: Codable {
            let version: Int
            let nonce: String
            let issuedAtMilliseconds: Int64
            let deadlineMilliseconds: Int64
            let request: BridgeRequestEnvelope
        }
        let value = UnsignedRequest(
            version: frame.version,
            nonce: frame.nonce,
            issuedAtMilliseconds: frame.issuedAtMilliseconds,
            deadlineMilliseconds: frame.deadlineMilliseconds,
            request: frame.request
        )
        return try canonicalData(value, domain: "notchhub.bridge.request.v1")
    }

    private static func responseAuthenticationData(_ frame: BridgeTransportResponseFrame) throws -> Data {
        struct UnsignedResponse: Codable {
            let version: Int
            let nonce: String
            let response: BridgeResponseEnvelope
        }
        let value = UnsignedResponse(version: frame.version, nonce: frame.nonce, response: frame.response)
        return try canonicalData(value, domain: "notchhub.bridge.response.v1")
    }

    private static func canonicalData(_ value: some Encodable, domain: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(domain.utf8)
        data.append(0)
        data.append(try encoder.encode(value))
        return data
    }
}
