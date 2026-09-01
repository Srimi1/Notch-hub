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

/// The overlay used to draw itself identically everywhere: an opaque black
/// rectangle with square top corners. That is correct only inside a real notch,
/// where the camera housing hides it. Anywhere else — iMac, Mac mini, external
/// display, MacBook in clamshell — it became an opaque black bar across the
/// middle of the menu bar.
@Suite("Overlay appearance follows the display")
struct HoverViewAppearanceTests {

    @Test
    @MainActor
    func notchlessDisplaysGetARoundedTranslucentChip() {
        let rect = CGRect(x: 0, y: 0, width: 190, height: 32)

        let notched = HoverView.cornerRadii(
            hasPhysicalNotch: true, bottomRadius: 10, in: rect
        )
        let notchless = HoverView.cornerRadii(
            hasPhysicalNotch: false, bottomRadius: 10, in: rect
        )

        // Inside a notch the top corners stay square — the bezel hides them.
        #expect(notched.top == 0)
        #expect(notched.bottom == 10)
        // Without a notch every corner is rounded, so it reads as a control.
        #expect(notchless.top == 10)
        #expect(notchless.bottom == 10)

        #expect(HoverView.backgroundAlpha(hasPhysicalNotch: true) == 1.0)
        #expect(
            HoverView.backgroundAlpha(hasPhysicalNotch: false) < 1.0,
            "A notchless display must not be blacked out."
        )
    }

    @Test
    @MainActor
    func radiiNeverExceedHalfTheSmallerSide() {
        let squat = CGRect(x: 0, y: 0, width: 190, height: 12)
        let radii = HoverView.cornerRadii(
            hasPhysicalNotch: false, bottomRadius: 24, in: squat
        )
        #expect(radii.bottom == 6)
        #expect(radii.top == 6)

        // A degenerate frame must not produce a negative radius.
        let empty = HoverView.cornerRadii(
            hasPhysicalNotch: false, bottomRadius: 10, in: .zero
        )
        #expect(empty.top == 0)
        #expect(empty.bottom == 0)
    }
}

/// Mach counter handling. Both of these only bite after the app has been
/// running far longer than a development session.
@Suite("Mach counter safety")
struct SystemMonitorMachTests {

    /// `cpu_ticks` are UInt32 and wrap after roughly 20–60 days of uptime.
    /// Plain subtraction traps on that wrap and kills the whole menu-bar agent.
    @Test
    func tickDeltaSurvivesCounterWraparound() {
        #expect(SystemMonitorService.tickDelta(500, 200) == 300)
        #expect(SystemMonitorService.tickDelta(0, 0) == 0)

        // The wrap: previous sample near the ceiling, current just past it.
        let justBelowCeiling = natural_t.max - 5
        #expect(SystemMonitorService.tickDelta(4, justBelowCeiling) == 10)
        #expect(SystemMonitorService.tickDelta(0, natural_t.max) == 1)
    }

    /// `mach_host_self()` hands back a fresh send right on every call, so a
    /// sampler that never deallocates leaks kernel resources for the life of
    /// the process. Repeated sampling must keep working and keep returning
    /// sane values — a port-right exhaustion would show up here as failures.
    @Test
    func repeatedHostStatisticsSamplingKeepsWorking() {
        var samples = 0
        for _ in 0 ..< 500 where SystemMonitorService.vmSnapshot() != nil {
            samples += 1
        }
        // Sandboxed CI may refuse host statistics entirely; only assert
        // consistency when the platform actually answered.
        guard samples > 0 else { return }
        #expect(samples == 500, "Sampling degraded partway through.")

        let used = SystemMonitorService.usedMemoryBytes()
        #expect(used ?? 1 > 0)
    }
}

/// Hovering the notch made it flicker open and shut under a stationary
/// pointer. Resizing the overlay tears down and rebuilds the tracking area,
/// and AppKit delivers the exit from the old one without an enter for the new
/// one — so the collapse that exit caused was immediately undone by the
/// reconcile, and round it went.
@Suite("Notch hover gating")
@MainActor
struct HoverGatingTests {

    private func makeView() -> (HoverView, Box) {
        let view = HoverView(frame: NSRect(x: 0, y: 0, width: 179, height: 32))
        let box = Box()
        view.onHoverChange = { box.values.append($0) }
        return (view, box)
    }

    final class Box {
        var values: [Bool] = []
    }

    /// Enter and exit events that arrive while the frame is moving are the
    /// unreliable ones, so they are dropped rather than acted on.
    @Test
    func eventsDuringAFrameAnimationAreIgnored() {
        let (view, box) = makeView()

        view.isFrameAnimating = true
        view.handleTransientHover(true)
        view.handleTransientHover(false)

        #expect(box.values.isEmpty)
    }

    /// Once the frame settles the events are honoured again.
    @Test
    func eventsAreHonouredOnceTheFrameSettles() {
        let (view, box) = makeView()

        view.isFrameAnimating = false
        view.handleTransientHover(true)

        #expect(box.values == [true])
    }

    /// Settling the frame drops the gate, so hover works again even when the
    /// settle comes from the controller's fallback rather than the animation's
    /// own completion. Without a window the reconcile inside it is a no-op, which
    /// is exactly what isolates the gate-clearing behaviour under test.
    @Test
    func settlingTheFrameClearsTheGate() {
        let (view, box) = makeView()

        view.isFrameAnimating = true
        view.handleTransientHover(true) // dropped while the frame moves
        #expect(box.values.isEmpty)

        view.endFrameAnimation()
        #expect(view.isFrameAnimating == false)

        view.handleTransientHover(true) // honoured again
        #expect(box.values == [true])
    }

    /// Repeats say nothing new. Dropping them keeps the reconcile after every
    /// animation free, and stops a reconcile that agrees with the current
    /// state from restarting anything.
    @Test
    func onlyChangesAreReported() {
        let (view, box) = makeView()

        view.handleTransientHover(true)
        view.handleTransientHover(true)
        view.handleTransientHover(false)
        view.handleTransientHover(false)

        #expect(box.values == [true, false])
    }
}
