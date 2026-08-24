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

    @Test
    func settingsSectionsAreStableAndDistinct() {
        #expect(SettingsSection.allCases.map(\.rawValue) == ["nextUp"])
        #expect(Set(SettingsSection.allCases.map(\.id)).count == SettingsSection.allCases.count)
    }
}
