import AppKit
import Foundation
import Testing
@testable import NotchHub

/// The trigger is a plain letter, so the same key press is also ordinary
/// typing — and a global monitor cannot swallow it. Everything here is about
/// when the gesture must *not* fire.
@Suite("Double-tap trigger")
struct KeyDoubleTapTests {

    private struct Press {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let at: TimeInterval

        init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ at: TimeInterval) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.at = at
        }
    }

    private let keyN = KeyDoubleTap.keyCodeN
    private let keyX: UInt16 = 7 // kVK_ANSI_X

    /// Feeds a sequence of presses and reports how many times the gesture
    /// fired.
    private func firings(_ presses: [Press]) -> Int {
        var state = KeyDoubleTap.State()
        var count = 0
        for press in presses {
            let result = KeyDoubleTap.evaluate(
                state: state,
                keyCode: press.keyCode,
                modifiers: press.modifiers,
                timestamp: press.at
            )
            state = result.state
            if result.fired { count += 1 }
        }
        return count
    }

    /// The gesture itself: quiet keyboard, two quick taps.
    @Test
    func twoQuickTapsAfterAPauseFire() {
        #expect(firings([Press(keyN, [], 5.0), Press(keyN, [], 5.2)]) == 1)
    }

    /// The reason for the idle rule. Every double letter in English arrives
    /// hard on the heels of the letter before it.
    @Test
    func typingAWordWithADoubleNDoesNotFire() {
        // a-n-n-o, at a brisk but ordinary pace.
        #expect(firings([
            Press(keyX, [], 4.90),
            Press(keyN, [], 5.00),
            Press(keyN, [], 5.10),
            Press(keyX, [], 5.20)
        ]) == 0)
    }

    /// Anything in between ends the pair — the two taps have to be adjacent.
    @Test
    func anInterveningKeyBreaksThePair() {
        #expect(firings([Press(keyN, [], 5.0), Press(keyX, [], 5.05), Press(keyN, [], 5.1)]) == 0)
    }

    /// Too slow is just two letters.
    @Test
    func aSlowSecondTapDoesNotFire() {
        #expect(firings([Press(keyN, [], 5.0), Press(keyN, [], 5.0 + KeyDoubleTap.tapWindow + 0.05)]) == 0)
    }

    /// ⌘N is New, ⇧N is a capital. Neither is the gesture.
    @Test
    func modifiedTapsAreTyping() {
        #expect(firings([Press(keyN, .command, 5.0), Press(keyN, .command, 5.2)]) == 0)
        #expect(firings([Press(keyN, .shift, 5.0), Press(keyN, .shift, 5.2)]) == 0)
        // A modified tap also breaks a pair in progress.
        #expect(firings([Press(keyN, [], 5.0), Press(keyN, .shift, 5.1), Press(keyN, [], 5.2)]) == 0)
    }

    /// A third tap starts over rather than firing again, so leaning on the key
    /// opens the picker once.
    @Test
    func aTripleTapFiresOnce() {
        #expect(firings([Press(keyN, [], 5.0), Press(keyN, [], 5.1), Press(keyN, [], 5.2)]) == 1)
    }

    /// The very first press of a session has no keystroke before it to be too
    /// close to.
    @Test
    func theFirstTapOfASessionQualifies() {
        #expect(firings([Press(keyN, [], 0.5), Press(keyN, [], 0.7)]) == 1)
    }
}

/// The monitor around the detector: installed once, only with Accessibility,
/// and torn down cleanly.
@Suite("Double-tap monitor")
@MainActor
struct KeyDoubleTapMonitorTests {

    private final class Spy: @unchecked Sendable {
        var installs = 0
        var removals = 0
    }

    private func makeMonitor(trusted: Bool, spy: Spy) -> KeyDoubleTapMonitor {
        KeyDoubleTapMonitor(
            isTrusted: { trusted },
            installMonitor: { _ in
                spy.installs += 1
                return NSObject()
            },
            removeMonitor: { _ in spy.removals += 1 }
        )
    }

    /// Without the grant the gesture is simply not available — and no prompt
    /// is raised, which belongs to onboarding.
    @Test
    func withoutAccessibilityNothingIsInstalled() {
        let spy = Spy()
        let monitor = makeMonitor(trusted: false, spy: spy)

        monitor.start()

        #expect(monitor.isRunning == false)
        #expect(spy.installs == 0)
    }

    @Test
    func startingIsIdempotentAndStoppingTearsDown() {
        let spy = Spy()
        let monitor = makeMonitor(trusted: true, spy: spy)

        monitor.start()
        monitor.start()
        #expect(monitor.isRunning)
        #expect(spy.installs == 1)

        monitor.stop()
        #expect(monitor.isRunning == false)
        #expect(spy.removals == 1)
    }
}
