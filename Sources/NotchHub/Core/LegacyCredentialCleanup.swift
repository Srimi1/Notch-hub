import Foundation
import Security

/// One-shot removal of the state the AI credit tracker left behind.
///
/// Deleting the tracker's code does not delete what it wrote: provider API keys
/// live in the login keychain, and two non-secret settings live in
/// `UserDefaults`. Leaving working credentials on someone's machine with no app
/// left to manage them is not acceptable, so this clears them once at launch.
///
/// Unelevated by design — `SecItemDelete` on the app's own generic-password
/// items needs no privileges and shows no prompt. This whole file is disposable:
/// once a release carrying it has shipped and run, it can be deleted.
enum LegacyCredentialCleanup {

    /// The `kSecAttrService` namespace the removed `KeychainStore` wrote under.
    static let service = "com.notchhub.apikeys"

    /// Keychain accounts — the raw values of the removed `CreditProvider`.
    static let accounts = ["grok", "anthropic", "openai", "google"]

    /// Non-secret keys written by the removed `CreditPreferences`.
    static let defaultsKeys = ["credit.grok.teamID", "credit.anthropic.rateLimitProbe"]

    /// Set once the purge has run, so it never repeats.
    static let completionKey = "didPurgeLegacyCredentials"

    /// Delete the leftovers, then record that we did. Safe to call every launch.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }

        for account in accounts {
            deleteKey(account: account)
        }
        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: completionKey)
    }

    /// Remove one provider key. `errSecItemNotFound` is the ordinary result for a
    /// user who never saved that provider, so it is not reported; anything else
    /// is logged, since a key we failed to delete is a key still on disk.
    @discardableResult
    static func deleteKey(account: String, service: String = LegacyCredentialCleanup.service) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            NSLog("NotchHub cleanup: could not remove stored key for %@ (OSStatus %d)", account, status)
        }
        return status
    }
}
