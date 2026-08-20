import Foundation
import Security

/// The single place API secrets are persisted. Wraps the Security framework's
/// generic-password items — one per provider account — so a key never lands in
/// `UserDefaults`, a JSON file, or a log.
///
/// Storage targets the **file-based login keychain** (the default on macOS): we
/// deliberately do *not* set data-protection attributes (`kSecAttrAccessible`,
/// `kSecUseDataProtectionKeychain`). NotchHub ships ad-hoc-signed and
/// un-sandboxed with no `keychain-access-groups` entitlement, and the
/// data-protection keychain would reject `SecItemAdd` with
/// `errSecMissingEntitlement` (-34018) in that configuration. Items in the login
/// keychain are readable while it's unlocked (i.e. after login), which covers
/// background polling fine. If the app is later sandboxed + entitled, switching
/// to the data-protection keychain is an additive change behind this same API.
enum KeychainStore {

    /// `kSecAttrService` namespace shared by every NotchHub API-key item.
    static let service = "com.notchhub.apikeys"

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    /// Add-or-update the secret for `account` (a `CreditProvider.rawValue`).
    static func save(_ secret: String, account: String, service: String = KeychainStore.service) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let existing = SecItemCopyMatching(base as CFDictionary, nil)
        switch existing {
        case errSecSuccess:
            let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        case errSecItemNotFound:
            var add = base
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        default:
            throw KeychainError.unexpectedStatus(existing)
        }
    }

    /// Read the secret for `account`, or `nil` if none is stored.
    static func read(account: String, service: String = KeychainStore.service) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError.encodingFailed
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Remove the secret for `account`. Idempotent — a missing item is success.
    static func delete(account: String, service: String = KeychainStore.service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Whether a secret exists for `account`, without returning it (used to show
    /// a masked placeholder in settings rather than reading the key back).
    static func hasKey(account: String, service: String = KeychainStore.service) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.unexpectedStatus(status)
        }
    }
}
