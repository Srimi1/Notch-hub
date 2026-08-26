import Foundation
import Testing
@testable import NotchHub

/// The switch that decides whether NotchHub ever opens a folder, and the list
/// of folders it has been allowed to open.
@Suite("Screenshot settings")
@MainActor
struct ScreenshotPreferencesTests {

    /// Preferences over a defaults domain of their own, so a test can never
    /// write to the ones the running app is reading.
    private struct Isolated {
        var preferences: ScreenshotPreferences
        var defaults: UserDefaults
        var suiteName: String
    }

    private static func makeIsolated() -> Isolated? {
        let suiteName = "ScreenshotPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults")
            return nil
        }
        return Isolated(
            preferences: ScreenshotPreferences(defaults: defaults),
            defaults: defaults,
            suiteName: suiteName
        )
    }

    /// A background app with no window cannot explain a permission prompt at
    /// login, so nothing may be on until the user asks for it.
    @Test
    func everythingIsOffUntilTheUserAsksForIt() {
        guard let rig = Self.makeIsolated() else { return }
        let (preferences, defaults, suiteName) = (rig.preferences, rig.defaults, rig.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(preferences.autoCopy == false)
        #expect(preferences.trashAfterCopying == false)
        #expect(preferences.allowedFolders.isEmpty)
    }

    /// And a choice has to survive a relaunch, or the feature switches itself
    /// off every morning.
    @Test
    func theSwitchesSurviveARelaunch() {
        guard let rig = Self.makeIsolated() else { return }
        let (preferences, defaults, suiteName) = (rig.preferences, rig.defaults, rig.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        preferences.autoCopy = true
        preferences.trashAfterCopying = true
        let reloaded = ScreenshotPreferences(defaults: defaults)

        #expect(reloaded.autoCopy)
        #expect(reloaded.trashAfterCopying)
    }

    /// Granting is per folder, because macOS grants per folder. Pointing
    /// `screencapture` somewhere new must not inherit the old permission.
    @Test
    func aGrantIsRememberedForThatFolderOnly() {
        guard let rig = Self.makeIsolated() else { return }
        let (preferences, defaults, suiteName) = (rig.preferences, rig.defaults, rig.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let desktop = URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)
        let downloads = URL(fileURLWithPath: "/Users/tester/Downloads", isDirectory: true)

        preferences.allow(desktop)

        #expect(preferences.isAllowed(desktop))
        #expect(preferences.isAllowed(downloads) == false)
    }

    /// `~/Desktop` and `~/Desktop/` are one grant. Two spellings would mean a
    /// folder the user already allowed asking again.
    @Test
    func aTrailingSlashIsTheSameGrant() {
        guard let rig = Self.makeIsolated() else { return }
        let (preferences, defaults, suiteName) = (rig.preferences, rig.defaults, rig.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        preferences.allow(URL(fileURLWithPath: "/Users/tester/Desktop/", isDirectory: true))

        #expect(preferences.isAllowed(URL(fileURLWithPath: "/Users/tester/Desktop")))
        #expect(preferences.allowedFolders.count == 1)
    }

    /// A revoked grant has to stop the watching, so denial can be recorded.
    @Test
    func forgettingAFolderRevokesTheGrant() {
        guard let rig = Self.makeIsolated() else { return }
        let (preferences, defaults, suiteName) = (rig.preferences, rig.defaults, rig.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let desktop = URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)
        preferences.allow(desktop)

        preferences.forget(desktop)

        #expect(preferences.isAllowed(desktop) == false)
    }

    /// A defaults domain is a file anything running as the user can write, so
    /// what comes back out of it is external data. A relative path is not a
    /// folder identity and must not become one.
    @Test
    func storedPathsAreValidatedOnTheWayBackIn() {
        let validated = ScreenshotPreferences.validated(
            ["/Users/tester/Desktop", "relative/path", "", "/Users/tester/Desktop/"]
        )

        #expect(validated == ["/Users/tester/Desktop"])
    }

    /// And the list stays bounded, so a long-lived install does not accumulate
    /// an unbounded thing to validate on every launch.
    @Test
    func theGrantListStaysBounded() {
        let many = (0 ..< 40).map { "/Users/tester/Folder\($0)" }

        let validated = ScreenshotPreferences.validated(many)

        #expect(validated.count == ScreenshotPreferences.allowedFolderLimit)
    }
}
