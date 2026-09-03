import CoreGraphics
import Testing
@testable import NotchHubSafeFeatures

@Suite("Compact notch geometry")
struct NotchOverlayGeometryTests {
    @Test("Physical notch idle and wings follow the hardware")
    func physicalNotchGeometry() {
        let geometry = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 32,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 666.5
        )

        #expect(geometry.hasPhysicalNotch)
        #expect(geometry.compactSize(showsWings: false) == .init(width: 179, height: 32))
        #expect(geometry.compactSize(showsWings: true) == .init(width: 427, height: 32))
        #expect(geometry.navigationGapWidth == 203)
    }

    @Test("Notchless displays use the compact fallback")
    func notchlessGeometry() {
        let geometry = NotchOverlayGeometry(
            screenWidth: 1_440,
            safeAreaTop: 24,
            leftAuxiliaryWidth: 0,
            rightAuxiliaryWidth: 0
        )

        #expect(!geometry.hasPhysicalNotch)
        #expect(geometry.compactSize(showsWings: false) == .init(width: 190, height: 32))
        #expect(geometry.compactSize(showsWings: true) == .init(width: 438, height: 32))
    }

    @Test("Transient or implausible screen metrics cannot create an oversized notch")
    func invalidNotchMetricsFallBack() {
        let missingSide = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 32,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 0
        )
        let tinyAuxiliaryAreas = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 32,
            leftAuxiliaryWidth: 10,
            rightAuxiliaryWidth: 10
        )
        let implausiblyTall = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 200,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 666.5
        )

        for geometry in [missingSide, tinyAuxiliaryAreas, implausiblyTall] {
            #expect(!geometry.hasPhysicalNotch)
            #expect(geometry.compactSize(showsWings: false) == .init(width: 190, height: 32))
        }
    }

    @Test("Expanded ribbon stays shallow and respects narrow displays")
    func expandedGeometry() {
        let standard = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 32,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 666.5
        )
        let tall = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 38,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 666.5
        )

        #expect(standard.expandedSize(availableWidth: 1_512) == .init(width: 860, height: 136))
        #expect(standard.expandedSize(availableWidth: 700) == .init(width: 660, height: 136))
        #expect(standard.expandedSize(availableWidth: 300) == .init(width: 260, height: 136))
        #expect(tall.expandedSize(availableWidth: 1_512) == .init(width: 860, height: 138))
    }

    @Test("Panel frames stay centered and attached to the top edge")
    func panelFramePolicy() {
        let geometry = NotchOverlayGeometry(
            screenWidth: 1_512,
            safeAreaTop: 32,
            leftAuxiliaryWidth: 666.5,
            rightAuxiliaryWidth: 666.5
        )
        let screen = CGRect(x: -200, y: 100, width: 1_512, height: 982)

        #expect(
            NotchOverlayFramePolicy.frame(
                in: screen,
                geometry: geometry,
                isExpanded: false,
                showsWings: true
            ) == CGRect(x: 342.5, y: 1050, width: 427, height: 32)
        )
        #expect(
            NotchOverlayFramePolicy.frame(
                in: screen,
                geometry: geometry,
                isExpanded: true,
                showsWings: false
            ) == CGRect(x: 126, y: 946, width: 860, height: 136)
        )
    }
}

@Suite("Compact notch hover gate")
struct NotchHoverGateTests {
    @Test("Transient resize events are ignored and settled pointer state wins")
    func animationGateReconciles() {
        var gate = NotchHoverGate()

        #expect(gate.handleTransient(true) == true)
        gate.beginFrameAnimation()
        #expect(gate.handleTransient(false) == nil)
        #expect(gate.isHovered)
        #expect(gate.finishFrameAnimation(pointerIsInside: false) == false)
        #expect(!gate.isHovered)
    }

    @Test("Repeated hover values do not restart transitions")
    func duplicateValuesAreDropped() {
        var gate = NotchHoverGate()

        #expect(gate.handleTransient(false) == nil)
        #expect(gate.handleTransient(true) == true)
        #expect(gate.handleTransient(true) == nil)
        gate.beginFrameAnimation()
        #expect(gate.finishFrameAnimation(pointerIsInside: true) == nil)
    }
}
