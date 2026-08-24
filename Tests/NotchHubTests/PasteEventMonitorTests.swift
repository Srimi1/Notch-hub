import AppKit
import Testing
@testable import NotchHub

/// The paste monitor is the one piece of this app that could observe keys
/// outside it, so its gating is pinned hard: no Accessibility grant, no monitor,
/// and it never outlives the popup it serves.
@Suite("Paste monitor")
@MainActor
struct PasteEventMonitorTests {

    private final class Spy {
        var installed = 0
        var removed = 0
    }

    private func makeMonitor(trusted: Bool, spy: Spy) -> PasteEventMonitor {
        PasteEventMonitor(
            isTrusted: { trusted },
            installMonitor: { _ in
                spy.installed += 1
                return NSObject()
            },
            removeMonitor: { _ in spy.removed += 1 }
        )
    }

    @Test
    func withoutAccessibilityTheMonitorIsNeverInstalled() {
        let spy = Spy()
        let monitor = makeMonitor(trusted: false, spy: spy)

        monitor.start()

        #expect(spy.installed == 0)
        #expect(!monitor.isRunning)
    }

    @Test
    func withAccessibilityItInstallsOnceAndTearsDownWithThePopup() {
        let spy = Spy()
        let monitor = makeMonitor(trusted: true, spy: spy)

        monitor.start()
        monitor.start() // popup content replaced — must not stack monitors

        #expect(spy.installed == 1)
        #expect(monitor.isRunning)

        monitor.stop()
        #expect(spy.removed == 1)
        #expect(!monitor.isRunning)

        monitor.stop() // double-stop is harmless
        #expect(spy.removed == 1)
    }

    @Test
    func onlyCommandVCounts() {
        #expect(PasteEventMonitor.isCommandV(characters: "v", modifiers: .command))
        #expect(PasteEventMonitor.isCommandV(characters: "V", modifiers: .command))
        // Paste-and-match-style is still a paste.
        #expect(PasteEventMonitor.isCommandV(characters: "v", modifiers: [.command, .shift]))

        #expect(!PasteEventMonitor.isCommandV(characters: "v", modifiers: []))
        #expect(!PasteEventMonitor.isCommandV(characters: "v", modifiers: .control))
        #expect(!PasteEventMonitor.isCommandV(characters: "c", modifiers: .command))
        #expect(!PasteEventMonitor.isCommandV(characters: nil, modifiers: .command))
    }
}
