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

    /// The hover-proof ceiling must sit at or above the longest dwell the user
    /// can pick, or it would cut a non-hovered popup short; and it stays bounded
    /// so a hovered popup can never hang.
    @Test
    func theHoverCeilingCoversTheLongestDwellAndStaysBounded() {
        #expect(NotchViewModel.hudHoverCeiling >= CopyPopupDurationPreset.long.duration)
        #expect(NotchViewModel.hudHoverCeiling <= 8)
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
        #expect(prefs.copyPopupDuration == .brief)
        #expect(prefs.chargingPopup)

        prefs.copyPopup = false
        prefs.copyPopupDuration = .long
        prefs.chargingPopup = false
        let reloaded = HudPreferences(defaults: defaults)
        #expect(!reloaded.copyPopup)
        #expect(reloaded.copyPopupDuration == .long)
        #expect(!reloaded.chargingPopup)
    }

    @Test
    func durationPresetsHaveStableLabelsAndIntervals() {
        #expect(CopyPopupDurationPreset.allCases == [.brief, .standard, .long])
        #expect(CopyPopupDurationPreset.allCases.map(\.title) == ["Brief", "Standard", "Long"])
        #expect(CopyPopupDurationPreset.allCases.map(\.duration) == [1.5, 2.5, 4.0])
    }

    @Test
    func anUnknownStoredDurationFallsBackToBrief() {
        let suite = "HudTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-value", forKey: "hud.copyPopupDuration")

        #expect(HudPreferences(defaults: defaults).copyPopupDuration == .brief)
    }
}

@Suite("Copy HUD countdown")
struct HudDismissCountdownTests {
    @Test
    func aRunningCountdownExpiresFromMonotonicTime() {
        var countdown = HUDDismissCountdown()

        #expect(countdown.start(duration: 1.5, now: 10, paused: false) == 1.5)
        #expect(countdown.deadline == 11.5)
        #expect(countdown.remaining(at: 10.5) == 1.0)
        #expect(countdown.remaining(at: 12) == 0)
    }

    @Test
    func hoverResumesOnlyTheTimeThatWasLeft() {
        var countdown = HUDDismissCountdown()
        _ = countdown.start(duration: 1.5, now: 10, paused: false)

        countdown.pause(now: 10.6)
        #expect(countdown.deadline == nil)
        #expect(abs((countdown.remaining ?? 0) - 0.9) < 0.000_1)

        // Repeated hover events are inert rather than consuming time twice.
        countdown.pause(now: 40)
        #expect(abs((countdown.remaining ?? 0) - 0.9) < 0.000_1)

        let resumed = countdown.resume(now: 50)
        #expect(abs((resumed ?? 0) - 0.9) < 0.000_1)
        #expect(abs((countdown.deadline ?? 0) - 50.9) < 0.000_1)
        #expect(countdown.resume(now: 50.1) == nil)
    }

    @Test
    func aNewCopyResetsWhileRemainingPausedUnderThePointer() {
        var countdown = HUDDismissCountdown()
        _ = countdown.start(duration: 1.5, now: 10, paused: false)
        countdown.pause(now: 11)

        #expect(countdown.start(duration: 4, now: 20, paused: true) == nil)
        #expect(countdown.remaining == 4)
        #expect(countdown.deadline == nil)
        #expect(countdown.resume(now: 30) == 4)
        #expect(countdown.deadline == 34)
    }

    @Test
    func dismissalClearsEveryPendingValue() {
        var countdown = HUDDismissCountdown()
        _ = countdown.start(duration: 1.5, now: 10, paused: false)

        countdown.clear()

        #expect(countdown.remaining == nil)
        #expect(countdown.deadline == nil)
        #expect(countdown.resume(now: 11) == nil)
    }
}
