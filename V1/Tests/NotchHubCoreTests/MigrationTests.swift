import Foundation
import Testing
@testable import NotchHubCore

@MainActor
@Suite("Legacy preference migration")
struct MigrationTests {
    @Test("Supported preferences migrate, including Media")
    func supportedValues() throws {
        try withDefaultsPair { legacy, destination in
            legacy.set(
                ["media", "calendar", "clipboard", "aiCoding", "focus"],
                forKey: "visibleModules"
            )
            legacy.set("media", forKey: "lastActiveModule")
            legacy.set(false, forKey: "hotkey.clipPicker.enabled")
            legacy.set("command.shift.v", forKey: "hotkey.clipPicker.spec")
            legacy.set("secret-value", forKey: "credit.openai.apiKey")

            let result = LegacyPreferencesMigrator.migrate(from: legacy, to: destination)
            let state = try #require(migratedState(result))

            #expect(state.visibleCapabilities == [.agents, .media, .clipboard, .focus])
            #expect(state.lastActiveCapability == .media)
            #expect(!state.clipboardHotKeyEnabled)
            #expect(state.clipboardHotKeyID == "command.shift.v")
            #expect(destination.object(forKey: "credit.openai.apiKey") == nil)
        }
    }

    @Test("Fresh defaults receive the complete V1 capability set")
    func freshDefaults() throws {
        try withDefaultsPair { legacy, destination in
            let result = LegacyPreferencesMigrator.migrate(from: legacy, to: destination)
            let state = try #require(migratedState(result))
            #expect(state.visibleCapabilities == [.agents, .dashboard, .media, .clipboard, .focus])
            #expect(state.lastActiveCapability == .agents)
        }
    }

    @Test("Migration is idempotent")
    func idempotence() throws {
        try withDefaultsPair { legacy, destination in
            _ = LegacyPreferencesMigrator.migrate(from: legacy, to: destination)
            #expect(LegacyPreferencesMigrator.migrate(from: legacy, to: destination) == .alreadyCompleted)
        }
    }

    private func migratedState(_ result: LegacyMigrationResult) -> V1PreferenceState? {
        guard case let .migrated(state) = result else { return nil }
        return state
    }

    private func withDefaultsPair(
        _ operation: (UserDefaults, UserDefaults) throws -> Void
    ) throws {
        let legacyName = "NotchHubLegacyTests.\(UUID().uuidString)"
        let destinationName = "NotchHubV1Tests.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        try operation(legacy, destination)
        legacy.removePersistentDomain(forName: legacyName)
        destination.removePersistentDomain(forName: destinationName)
    }
}
