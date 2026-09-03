import Testing
@testable import NotchHubSafeFeatures

@MainActor
@Suite("Safe notch presentation")
struct SafeNotchPresentationModelTests {
    @Test("Selecting a feature expands the notch and preserves workspace state")
    func selectionExpands() {
        let workspace = SafeFeatureWorkspace(focus: FocusTimerModel(minutes: 50))
        let model = SafeNotchPresentationModel(workspace: workspace)
        var layoutChanges = 0
        model.setLayoutChangeHandler { layoutChanges += 1 }

        model.select(.focus)

        #expect(model.tier == .detail)
        #expect(model.selectedFeature == .focus)
        #expect(model.workspace === workspace)
        #expect(model.workspace.focus.selectedMinutes == 50)
        #expect(layoutChanges == 1)
    }

    @Test("Panel metrics track compact and detail tiers")
    func panelMetricsTrackTier() {
        let model = SafeNotchPresentationModel()
        #expect(model.panelMetrics == .init(width: 190, height: 32))

        model.showDetail()
        #expect(model.panelMetrics == .init(width: 860, height: 136))

        model.showCompact()
        #expect(model.panelMetrics == .init(width: 190, height: 32))
    }

    @Test("The Lite feature surface is closed and sandbox-safe")
    func featureSurface() {
        #expect(SafeFeature.allCases == [.dashboard, .clipboard, .focus])
        #expect(SafeFeature.allCases.map(\.title) == ["Dashboard", "Clipboard", "Focus"])
    }
}
