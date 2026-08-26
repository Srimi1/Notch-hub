import AppKit
import SwiftUI
import Testing
@testable import NotchHub

/// Every control on the overlay used `.buttonStyle(.plain)`, which strips
/// hover, pressed and focus together and puts nothing back. These pin the
/// vocabulary that replaced it — and, more usefully, the *ordering* between the
/// surfaces, because that is the part a future colour tweak can quietly break.
@Suite("Overlay interaction")
struct NotchInteractionTests {

    /// The alpha a token actually resolves to, which is the only thing that
    /// decides whether one surface reads as stronger than another.
    private static func alpha(_ color: Color) -> CGFloat {
        NSColor(color).usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
    }

    @Test
    func aControlNobodyIsTouchingRests() {
        #expect(NotchInteraction.state(isHovered: false, isPressed: false) == .resting)
    }

    @Test
    func aControlUnderThePointerHovers() {
        #expect(NotchInteraction.state(isHovered: true, isPressed: false) == .hovered)
    }

    /// The pointer is necessarily over a control it is pressing, so both flags
    /// arrive together on every real click. If hover won, the press would never
    /// be seen and the click would go unconfirmed — which is the whole bug.
    @Test
    func aPressBeatsTheHoverItArrivesWith() {
        #expect(NotchInteraction.state(isHovered: true, isPressed: true) == .pressed)
        #expect(NotchInteraction.state(isHovered: false, isPressed: true) == .pressed)
    }

    /// Hover has to be visible against rest, and quieter than a selection, or
    /// it either says nothing or claims to be a state that stays.
    @Test
    func hoverSitsBetweenRestingAndSelected() {
        let resting = Self.alpha(NotchTheme.subtleSurface)
        let hover = Self.alpha(NotchTheme.hoverSurface)
        let selected = Self.alpha(NotchTheme.selectedSurface)

        #expect(resting < hover, "a hover that matches the resting fill says nothing")
        #expect(hover < selected, "a hover as strong as a selection claims to be one")
    }

    /// Pressed is the strongest fill on the panel on purpose: it lasts only as
    /// long as the mouse button, so it cannot be mistaken for a selection, and
    /// on a panel floating over another app it is the only confirmation that
    /// the click landed at all.
    @Test
    func pressedIsTheStrongestSurface() {
        let pressed = Self.alpha(NotchTheme.pressedSurface)

        #expect(pressed > Self.alpha(NotchTheme.selectedSurface))
        #expect(pressed > Self.alpha(NotchTheme.hoverSurface))
    }

    /// Each state has to resolve to a different fill, or two of them look the
    /// same and the vocabulary has three words for two things.
    @Test
    func everyStateLooksDifferentFromTheOthers() {
        let fills = [NotchInteraction.resting, .hovered, .pressed].map { Self.alpha($0.surface) }

        #expect(Set(fills).count == 3)
    }

    /// A thumbnail nested in a card has to be rounder-inside, not equal, or the
    /// two curves stop being concentric. It was three different literals.
    @Test
    func aNestedShapeIsRoundedInsideItsCard() {
        #expect(NotchTheme.innerRadius < NotchTheme.cardRadius)
        #expect(NotchTheme.innerRadius > 0)
    }
}
