import Foundation
import NotchHubNetwork
import Testing
@testable import NotchHub

@MainActor
@Suite("Network display preferences")
struct NetworkModulePreferencesTests {
    @Test
    func unitsPersistWithinTheAppAndInvalidValuesFallBack() throws {
        let suite = "NetworkPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = NetworkModulePreferences(defaults: defaults)
        #expect(preferences.unit == .megabitsPerSecond)
        preferences.unit = .megabytesPerSecond
        #expect(NetworkModulePreferences(defaults: defaults).unit == .megabytesPerSecond)

        defaults.set("obsolete-unit", forKey: NetworkModulePreferences.unitKey)
        #expect(NetworkModulePreferences(defaults: defaults).unit == .megabitsPerSecond)
    }
}
