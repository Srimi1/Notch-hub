import Foundation
import Testing
@testable import NotchHub

/// Module visibility is the app's main setting now, and it is also a privacy
/// switch — `ServiceHub` starts and stops real services from this list. What it
/// restores on launch therefore has to be exactly what the user chose.
@Suite("Module preferences")
struct ModulePreferencesTests {

    private func isolatedDefaults(_ label: String) -> (UserDefaults, String)? {
        let suite = "ModulePreferencesTests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        return (defaults, suite)
    }

    @Test
    func freshInstallGetsTheDefaultLayout() {
        guard let (defaults, suite) = isolatedDefaults("fresh") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = ModulePreferences(defaults: defaults)
        #expect(prefs.visibleModules == ModulePreferences.defaultVisibleModules)
    }

    /// The regression this suite exists for. Hiding everything used to read as
    /// "no preference stored", so every module came back on the next launch and
    /// the services behind them started again.
    @Test
    func hidingEveryModuleSurvivesRelaunch() {
        guard let (defaults, suite) = isolatedDefaults("empty") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = ModulePreferences(defaults: defaults)
        for module in FeatureModule.allCases {
            prefs.setModule(module, visible: false)
        }
        #expect(prefs.visibleModules.isEmpty)

        let relaunched = ModulePreferences(defaults: defaults)
        #expect(relaunched.visibleModules.isEmpty)
    }

    /// Layouts saved before `aiCoding` and `ramCleaner` were removed must load
    /// without losing the modules that do still exist.
    @Test
    func unknownModuleIDsAreDroppedFromASavedLayout() {
        guard let (defaults, suite) = isolatedDefaults("unknown") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["dashboard", "aiCoding", "ramCleaner", "focus"], forKey: "visibleModules")

        let prefs = ModulePreferences(defaults: defaults)
        #expect(prefs.visibleModules == [.dashboard, .focus])
    }

    /// A layout consisting *only* of removed modules is an obsolete file, not a
    /// deliberate empty choice — restore the defaults instead of an empty notch.
    @Test
    func aLayoutOfOnlyRemovedModulesFallsBackToDefaults() {
        guard let (defaults, suite) = isolatedDefaults("obsolete") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["aiCoding", "ramCleaner"], forKey: "visibleModules")

        let prefs = ModulePreferences(defaults: defaults)
        #expect(prefs.visibleModules == ModulePreferences.defaultVisibleModules)
    }

    /// The chip band reads this list directly, so its order must depend on the
    /// enum, not on the order the user happened to click the toggles.
    @Test
    func visibilityKeepsCanonicalOrderRegardlessOfToggleOrder() {
        guard let (defaults, suite) = isolatedDefaults("order") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = ModulePreferences(defaults: defaults)
        for module in FeatureModule.allCases {
            prefs.setModule(module, visible: false)
        }
        prefs.setModule(.focus, visible: true)
        prefs.setModule(.media, visible: true)

        #expect(prefs.visibleModules == [.media, .focus])
    }

    @Test
    func showingAnAlreadyVisibleModuleChangesNothing() {
        guard let (defaults, suite) = isolatedDefaults("noop") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = ModulePreferences(defaults: defaults)
        let before = prefs.visibleModules
        prefs.setModule(.dashboard, visible: true)
        #expect(prefs.visibleModules == before)
    }

    @Test
    func lastActiveModuleFallsBackToDashboardForARemovedID() {
        guard let (defaults, suite) = isolatedDefaults("active") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("ramCleaner", forKey: "lastActiveModule")

        let prefs = ModulePreferences(defaults: defaults)
        #expect(prefs.lastActiveModule == .dashboard)
    }
}
