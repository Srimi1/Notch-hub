import Foundation
import Testing
@testable import NotchHub

/// The credit tracker is gone, but the API keys it wrote to the login keychain
/// are not. The cleanup has to actually run, and has to run only once — a purge
/// that repeated every launch would keep reaching into the keychain forever.
@Suite("Legacy credential cleanup")
struct LegacyCredentialCleanupTests {

    /// A defaults domain of our own, so the test never disturbs a real install.
    private func makeDefaults(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: "notchhub.tests.\(name)")
    }

    @Test
    func clearsCreditDefaultsAndRecordsCompletion() throws {
        let suite = "cleanup-\(UUID().uuidString)"
        let defaults = try #require(makeDefaults(suite))
        defer { defaults.removePersistentDomain(forName: "notchhub.tests.\(suite)") }

        defaults.set("team-abc", forKey: "credit.grok.teamID")
        defaults.set(true, forKey: "credit.anthropic.rateLimitProbe")

        LegacyCredentialCleanup.runIfNeeded(defaults: defaults)

        #expect(defaults.object(forKey: "credit.grok.teamID") == nil)
        #expect(defaults.object(forKey: "credit.anthropic.rateLimitProbe") == nil)
        #expect(defaults.bool(forKey: LegacyCredentialCleanup.completionKey))
    }

    /// Once the flag is set the purge must not touch anything again, so a key a
    /// user deliberately stores later under the same name is left alone.
    @Test
    func doesNotRunASecondTime() throws {
        let suite = "cleanup-once-\(UUID().uuidString)"
        let defaults = try #require(makeDefaults(suite))
        defer { defaults.removePersistentDomain(forName: "notchhub.tests.\(suite)") }

        defaults.set(true, forKey: LegacyCredentialCleanup.completionKey)
        defaults.set("kept", forKey: "credit.grok.teamID")

        LegacyCredentialCleanup.runIfNeeded(defaults: defaults)

        #expect(defaults.string(forKey: "credit.grok.teamID") == "kept")
    }

    /// Deleting a key that was never saved is the ordinary case — a fresh
    /// install has none — and must be reported as success, not failure.
    @Test
    func deletingAnAbsentKeyIsNotAnError() {
        let status = LegacyCredentialCleanup.deleteKey(
            account: "notchhub-test-absent-\(UUID().uuidString)",
            service: "com.notchhub.tests.absent"
        )
        #expect(status == errSecItemNotFound)
    }

    /// The accounts list must match the providers the removed tracker supported,
    /// or a key would be left behind with nothing left to delete it.
    @Test
    func coversEveryProviderTheTrackerSupported() {
        #expect(LegacyCredentialCleanup.accounts == ["grok", "anthropic", "openai", "google"])
        #expect(LegacyCredentialCleanup.service == "com.notchhub.apikeys")
    }
}
