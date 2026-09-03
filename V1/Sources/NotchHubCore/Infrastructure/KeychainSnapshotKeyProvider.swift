import CryptoKit
import Foundation
import Security

public enum KeychainKeyError: Error, Equatable, Sendable {
    case queryFailed(OSStatus)
    case addFailed(OSStatus)
    case randomGenerationFailed(OSStatus)
    case invalidKeyLength
}

public struct KeychainSnapshotKeyProvider: SnapshotKeyProvider {
    public static let defaultService = "com.notchhub.v1.snapshots"
    public static let defaultAccount = "encryption-key-v1"

    private let service: String
    private let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try load() {
            return SymmetricKey(data: existing)
        }
        let generated = try generateKeyData()
        do {
            try add(generated)
            return SymmetricKey(data: generated)
        } catch KeychainKeyError.addFailed(errSecDuplicateItem) {
            guard let racedValue = try load() else {
                throw KeychainKeyError.queryFailed(errSecItemNotFound)
            }
            return SymmetricKey(data: racedValue)
        }
    }

    private func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainKeyError.queryFailed(status)
        }
        guard let data = item as? Data, data.count == 32 else {
            throw KeychainKeyError.invalidKeyLength
        }
        return data
    }

    private func add(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainKeyError.addFailed(status)
        }
    }

    private func generateKeyData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainKeyError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}
