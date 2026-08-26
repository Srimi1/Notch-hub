import AppKit
import Testing
@testable import NotchHub

@Suite("Polished Activity Presentation")
struct ActivityPresentationTests {
    @Test
    func compactLabelsRemoveRedundantWords() {
        let battery = ActivitySnapshot(
            id: "battery",
            kind: .battery,
            priority: .ambient,
            title: "Battery 86%",
            detail: "6h 48m remaining"
        )
        let timer = ActivitySnapshot(
            id: "timer",
            kind: .timer,
            priority: .normal,
            title: "Focus",
            detail: "Paused · 24:12 remaining"
        )

        #expect(battery.compactLabel == "86% · 6h 48m")
        #expect(timer.compactLabel == "24:12")
    }

    @Test
    @MainActor
    func ambientActivityDoesNotClaimWingsOrDetail() {
        let ambient = ActivitySnapshot(
            id: "battery",
            kind: .battery,
            priority: .ambient,
            title: "Battery 86%",
            detail: "6h remaining"
        )
        let urgent = ActivitySnapshot(
            id: "timer",
            kind: .timer,
            priority: .urgent,
            title: "Focus",
            detail: "00:30"
        )

        #expect(NotchViewModel.shouldShowCollapsedWings(ambient) == false)
        #expect(NotchViewModel.shouldPresentActivity(ambient) == false)
        #expect(NotchViewModel.shouldShowCollapsedWings(urgent))
        #expect(NotchViewModel.shouldPresentActivity(urgent))
    }
}

@Suite("Polished Notch Geometry")
struct PolishedNotchGeometryTests {
    @Test
    @MainActor
    func expandedSizeUsesComfortableCompactDimensions() {
        let standard = NotchWindowController.expandedSize(forScreenWidth: 1_470)
        #expect(standard.width == 860)
        #expect(standard.height == 136)
    }

    @Test
    @MainActor
    func expandedWidthLeavesScreenMargins() {
        let compact = NotchWindowController.expandedSize(forScreenWidth: 700)
        #expect(compact.width == 660)
        #expect(compact.height == 136)
    }

    /// A taller notch means a taller toggle band, and the window has to grow
    /// with it or the module row is pushed out through the bottom.
    @Test
    @MainActor
    func expandedHeightGrowsWithATallNotch() {
        #expect(NotchTheme.expandedHeight(notchHeight: 32) == 136)
        #expect(NotchTheme.expandedHeight(notchHeight: 38) == 138)
        #expect(NotchWindowController.expandedSize(
            forScreenWidth: 1_470,
            notchHeight: 38
        ).height == 138)
    }

    /// Each wing needs its outer padding as well as its own width, or the ends
    /// of the clock and the activity label sit under the camera housing.
    @Test
    @MainActor
    func collapsedWidthBudgetsBothWingsAndTheirPadding() {
        let wide = NotchWindowController.collapsedWidth(
            notchWidth: 179,
            showWings: true,
            wingWidth: 112,
            wingPadding: 12
        )
        #expect(wide == CGFloat(179 + (112 + 12) * 2))
    }

    /// Without an activity the pill is the bare notch — anything wider is an
    /// empty black slab, because nothing is drawn in the extra space.
    @Test
    @MainActor
    func collapsedWidthWithoutWingsIsTheBareNotch() {
        let narrow = NotchWindowController.collapsedWidth(
            notchWidth: 179,
            showWings: false,
            wingWidth: 112,
            wingPadding: 12
        )
        #expect(narrow == 179)
    }
}

@Suite("Polished Navigation and Settings")
struct NavigationAndSettingsTests {
    @Test
    func moduleShortcutsCoverOnlyOneThroughNine() {
        #expect(ModuleKeyboardShortcut.key(at: 0) != nil)
        #expect(ModuleKeyboardShortcut.key(at: 8) != nil)
        #expect(ModuleKeyboardShortcut.key(at: -1) == nil)
        #expect(ModuleKeyboardShortcut.key(at: 9) == nil)
    }

    /// Every module has to render something real. The dashboard's `switch` is
    /// exhaustive now that the "Planned" placeholder arm is gone, so an added
    /// case fails the build — this pins the list so the count can't drift back
    /// up by accident.
    @Test
    func featureModulesAreExactlyTheSevenThatExist() {
        #expect(FeatureModule.allCases.map(\.rawValue) == [
            "dashboard", "media", "calendar", "todo", "pomodoro", "clipboard", "focus"
        ])
        #expect(Set(FeatureModule.allCases.map(\.id)).count == FeatureModule.allCases.count)
        #expect(ModulePreferences.defaultVisibleModules == FeatureModule.allCases)
    }
}
