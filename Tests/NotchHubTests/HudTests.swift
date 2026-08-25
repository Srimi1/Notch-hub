import Foundation
import Testing
@testable import NotchHub

/// The copy popup's gating rules and its preferences.
@Suite("Copy HUD")
@MainActor
struct HudTests {

    @Test
    func popupShowsOnlyWhenEnabledAndCollapsed() {
        #expect(NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: false, hudContent: nil))
        // The dashboard already shows the clipboard — a popup over it is noise.
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: true, hudContent: nil))
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: false, isExpanded: false, hudContent: nil))
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: false, isExpanded: true, hudContent: nil))
    }

    @Test
    func preferencesDefaultOnAndRoundTrip() {
        let suite = "HudTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = HudPreferences(defaults: defaults)
        #expect(prefs.copyPopup)
        #expect(prefs.chargingPopup)

        prefs.copyPopup = false
        prefs.chargingPopup = false
        let reloaded = HudPreferences(defaults: defaults)
        #expect(!reloaded.copyPopup)
        #expect(!reloaded.chargingPopup)
    }
}
