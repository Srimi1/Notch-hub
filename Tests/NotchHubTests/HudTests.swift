import Foundation
import Testing
@testable import NotchHub

/// The copy popup's gating rules and its preferences.
@Suite("Copy HUD")
@MainActor
struct HudTests {

    /// The key monitors follow the HUD tier from one table. Two of them leaked
    /// when this lived at the call sites, so the mapping is pinned here.
    @Test
    func monitorsAreDerivedFromTheHudTier() {
        let clip = ClipboardService.Clip(id: UUID(), kind: .text("x"), date: .now)
        #expect(NotchViewModel.monitorPolicy(for: .clip(clip)) == (paste: true, picker: false))
        #expect(NotchViewModel.monitorPolicy(for: .clipPicker) == (paste: false, picker: true))
        #expect(NotchViewModel.monitorPolicy(for: .peek) == (paste: false, picker: false))
        #expect(NotchViewModel.monitorPolicy(for: .charging) == (paste: false, picker: false))
        #expect(NotchViewModel.monitorPolicy(for: nil) == (paste: false, picker: false))
    }

    @Test
    func popupShowsOnlyWhenEnabledAndCollapsed() {
        #expect(NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: false, hudContent: nil))
        // The dashboard already shows the clipboard — a popup over it is noise.
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: true, isExpanded: true, hudContent: nil))
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: false, isExpanded: false, hudContent: nil))
        #expect(!NotchViewModel.shouldShowCopyHUD(popupEnabled: false, isExpanded: true, hudContent: nil))
    }

    /// The copy popup arms two timers: an ordinary dwell that hover pauses, and
    /// a hard ceiling that hover cannot touch, so the popup can never hang open
    /// under a cursor resting near the notch.
    @Test
    func aCopyPopupArmsAHardCeilingHoverCannotCancel() {
        let viewModel = NotchViewModel(preferences: ModulePreferences(), services: ServiceHub())
        let clip = ClipboardService.Clip(id: UUID(), kind: .text("x"), date: .now)

        #expect(viewModel.hudDismissDelay < viewModel.hudMaxLifetime)

        viewModel.showCopyHUD(clip)
        #expect(viewModel.pendingHudDismiss != nil)
        #expect(viewModel.pendingHudHardDismiss != nil)

        // Hover pauses the ordinary dwell but leaves the ceiling running.
        viewModel.setHudHover(true)
        #expect(viewModel.pendingHudDismiss == nil)
        #expect(viewModel.pendingHudHardDismiss != nil)

        // Clearing the popup drops both timers.
        viewModel.dismissHUD()
        #expect(viewModel.pendingHudDismiss == nil)
        #expect(viewModel.pendingHudHardDismiss == nil)
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
