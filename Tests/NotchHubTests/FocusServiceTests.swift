import Foundation
import Testing
@testable import NotchHub

/// The Focus toggle drives real UI through two separate permissions. What it
/// must never do is fail silently, blame the wrong permission, or undo a
/// successful toggle by reading state that has not been written yet.
@Suite("Focus toggle")
@MainActor
struct FocusServiceTests {

    /// A denied Apple Event is not a missing Accessibility grant. Sending the
    /// user to Accessibility — where NotchHub is already ticked — is what made
    /// this look unfixable.
    @Test
    func appleEventDenialIsReportedAsAutomationNotAccessibility() {
        #expect(FocusService.classify(errorNumber: -1743, message: nil) == .automationDenied)
        #expect(FocusService.classify(errorNumber: -600, message: nil) == .automationDenied)
        #expect(FocusService.ToggleError.automationDenied.settingsPane == .automation)
    }

    /// An Accessibility failure keeps pointing at Accessibility.
    @Test
    func assistiveAccessFailureIsReportedAsAccessibility() {
        #expect(FocusService.classify(errorNumber: -25211, message: nil) == .accessibilityDenied)
        #expect(
            FocusService.classify(
                errorNumber: nil,
                message: "System Events got an error: notchhub is not allowed assistive access."
            ) == .accessibilityDenied
        )
        #expect(FocusService.ToggleError.accessibilityDenied.settingsPane == .accessibility)
    }

    /// Our own script errors mean the control moved or was renamed — a
    /// different problem from a permission, and no pane fixes it.
    @Test
    func aMissingControlIsItsOwnFailureWithNoPaneToOpen() {
        #expect(FocusService.classify(errorNumber: -1728, message: "no opener") == .controlNotFound)
        #expect(FocusService.classify(errorNumber: nil, message: "no dnd control") == .controlNotFound)
        #expect(FocusService.ToggleError.controlNotFound.settingsPane == nil)
    }

    /// Anything unrecognized keeps its code rather than being discarded.
    @Test
    func anUnknownFailureCarriesItsCode() {
        #expect(FocusService.classify(errorNumber: -1712, message: "timed out") == .scriptFailed(code: -1712))
    }

    /// A successful toggle adopts the state Control Center reported and clears
    /// any stale error.
    @Test
    func aSuccessfulToggleAdoptsTheReportedState() async {
        let service = makeService(script: { .success(true) }, state: { nil })

        service.toggle()
        await settle()

        #expect(service.isOn)
        #expect(service.isStateKnown)
        #expect(service.lastError == nil)
        #expect(service.isToggling == false)
    }

    /// The bug this replaced: with no Full Disk Access the real state was never
    /// read, `isOn` sat at its `false` default, and the first toggle flipped it
    /// to `true` — so on a Mac where Do Not Disturb was already on, the button
    /// said "Turn On", turned it off, and the notch then showed a "Focus is on"
    /// pill for the rest of the session. Knowing nothing has to stay nothing.
    @Test
    func aToggleWithNothingReadableDoesNotInventAState() async {
        let service = makeService(script: { .success(nil) }, state: { nil })

        service.toggle()
        await settle()

        #expect(service.isStateKnown == false)
        #expect(service.isOn == false)
        #expect(service.lastError == nil)
    }

    /// Once the state is known, a click still flips it even if the control
    /// publishes no value — the starting point was sound.
    @Test
    func aKnownStateStillFlipsWhenTheControlSaysNothing() async {
        // Readable at launch, unreadable afterwards — the state is established
        // once and then has to survive on its own.
        let readings = Readings([false])
        let service = makeService(script: { .success(nil) }, state: { readings.next() })

        service.start()
        service.toggle()
        await settle()

        #expect(service.isOn)
        #expect(service.isStateKnown)
    }

    /// Reading the real file at launch is what makes the state known when Full
    /// Disk Access happens to be granted.
    @Test
    func startingWithAReadableFileMakesTheStateKnown() async {
        let service = makeService(script: { .success(nil) }, state: { true })

        service.start()

        #expect(service.isOn)
        #expect(service.isStateKnown)
    }

    @Test
    func theScriptsAnswerIsReadStrictly() {
        #expect(FocusService.reportedState("on") == true)
        #expect(FocusService.reportedState(" off\n") == false)
        #expect(FocusService.reportedState("unknown") == nil)
        #expect(FocusService.reportedState(nil) == nil)
        #expect(FocusService.reportedState("") == nil)
    }

    /// The regression that made the feature look dead: the assertions file is
    /// written asynchronously, so reconciling immediately reported the
    /// pre-toggle value and un-flipped the switch the user just used. State is
    /// only corrected after the delay.
    @Test
    func aStaleStateReadDoesNotUndoASuccessfulToggle() async {
        let recorder = Recorder()
        let service = FocusService(
            isTrusted: { true },
            runScript: { .success(true) },
            readState: { false }, // the file still says "off"
            promptForAccessibility: {},
            reconcile: { delay, _ in recorder.delays.append(delay) } // never fires
        )

        service.toggle()
        await settle()

        #expect(service.isOn)
        #expect(recorder.delays == [FocusService.reconcileDelay])
    }

    /// When the delayed read does arrive, it wins — that is the whole point of
    /// reconciling against the real file.
    @Test
    func theDelayedReadCorrectsTheOptimisticState() async {
        let service = FocusService(
            isTrusted: { true },
            runScript: { .success(true) },
            readState: { false },
            promptForAccessibility: {},
            reconcile: { _, work in work() }
        )

        service.toggle()
        await settle()

        #expect(service.isOn == false)
    }

    /// A failed toggle leaves the state alone and says why.
    @Test
    func aFailedToggleKeepsTheStateAndSurfacesTheReason() async {
        let service = makeService(script: { .failure(.automationDenied) }, state: { nil })

        service.toggle()
        await settle()

        #expect(service.isOn == false)
        #expect(service.lastError == .automationDenied)
        #expect(service.isToggling == false)
    }

    // MARK: - Helpers

    /// Captures the reconcile delays the service asks for. Unchecked: the
    /// service hands the closure back on the main actor, where these tests run.
    private final class Recorder: @unchecked Sendable {
        var delays: [TimeInterval] = []
    }

    /// Hands out a scripted sequence of state readings, then `nil` forever.
    private final class Readings: @unchecked Sendable {
        private var remaining: [Bool?]

        init(_ remaining: [Bool?]) { self.remaining = remaining }

        func next() -> Bool? {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }

    private func makeService(
        script: @escaping @Sendable () -> Result<Bool?, FocusService.ToggleError>,
        state: @escaping @Sendable () -> Bool?
    ) -> FocusService {
        FocusService(
            isTrusted: { true },
            runScript: script,
            readState: state,
            promptForAccessibility: {},
            reconcile: { _, work in work() }
        )
    }

    /// The toggle hops to a serial queue and back to the main actor.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
