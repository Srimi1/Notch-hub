import Foundation
import Testing
@testable import NotchHub

@MainActor
@Suite("Network tab sampling ownership")
struct NetworkModulePresentationTests {
    @Test
    func outgoingTransitionCannotStopTheReopenedTab() {
        let presentation = NetworkModulePresentation()
        let outgoing = UUID()
        let current = UUID()
        var starts = 0
        var stops = 0

        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(true, id: outgoing, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(true, id: outgoing, start: { starts += 1 }, stop: { stops += 1 })
        #expect(starts == 1)
        presentation.setVisible(true, id: current, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(false, id: outgoing, start: { starts += 1 }, stop: { stops += 1 })
        #expect(starts == 1)
        #expect(stops == 0)
        presentation.setVisible(false, id: current, start: { starts += 1 }, stop: { stops += 1 })
        #expect(stops == 1)
    }

    @Test
    func coalescedTabLeaveAndReturnRestartsWithoutAnotherAppearance() {
        let presentation = NetworkModulePresentation()
        let current = UUID()
        var starts = 0
        var stops = 0

        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(true, id: current, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(false, start: { starts += 1 }, stop: { stops += 1 })
        #expect(stops == 1)
        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })
        #expect(starts == 2)
    }

    @Test
    func coalescedCollapseAndExpandRestartsWithoutAnotherAppearance() {
        let presentation = NetworkModulePresentation()
        let current = UUID()
        var starts = 0
        var stops = 0

        presentation.setVisible(true, id: current, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(false, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })

        #expect(starts == 2)
        #expect(stops == 1)
    }

    @Test
    func ineligibleUnmountedContentDoesNotRestart() {
        let presentation = NetworkModulePresentation()
        let current = UUID()
        var starts = 0
        var stops = 0

        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(true, id: current, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(false, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setVisible(false, id: current, start: { starts += 1 }, stop: { stops += 1 })
        presentation.setEligible(true, start: { starts += 1 }, stop: { stops += 1 })

        #expect(starts == 1)
        #expect(stops == 1)
    }
}
