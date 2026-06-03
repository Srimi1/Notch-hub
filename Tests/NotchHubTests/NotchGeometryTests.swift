import AppKit
import Testing
@testable import NotchHub

// Uses swift-testing (`import Testing`), which ships with the Swift toolchain and
// works without full Xcode/XCTest (only Command Line Tools are installed here).
@Suite("NotchGeometry")
struct NotchGeometryTests {

    /// The notch-less fallback pill must be a sane, non-degenerate size so the
    /// collapsed UI is always usable on external displays / Intel Macs.
    @Test
    func fallbackDimensionsArePositive() {
        #expect(NotchGeometry.fallbackWidth > 0)
        #expect(NotchGeometry.fallbackHeight > 0)
        #expect(
            NotchGeometry.fallbackWidth >= NotchGeometry.fallbackHeight,
            "Pill should be wider than it is tall."
        )
    }

    /// With a real screen attached, geometry must yield a positive, screen-bounded
    /// notch size and never crash. No-ops in fully headless environments.
    @Test
    @MainActor
    func geometryFromMainScreenIsBounded() {
        guard let screen = NSScreen.main else { return }
        let geometry = NotchGeometry(screen: screen)

        #expect(geometry.notchSize.width > 0)
        #expect(geometry.notchSize.height > 0)
        #expect(
            geometry.notchSize.width <= screen.frame.width,
            "Notch can never be wider than the screen."
        )

        if !geometry.hasPhysicalNotch {
            #expect(geometry.notchSize.width == NotchGeometry.fallbackWidth)
        }
    }
}
