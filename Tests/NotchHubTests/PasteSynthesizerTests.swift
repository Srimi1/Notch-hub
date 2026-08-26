import AppKit
import Foundation
import Testing
@testable import NotchHub

/// Picking a clip should finish the paste, but only where macOS allows it —
/// and never at the cost of losing the copy.
@Suite("Paste synthesizer")
@MainActor
struct PasteSynthesizerTests {

    /// A recorder standing in for the event tap. Unchecked: every call in these
    /// tests happens on the main actor, synchronously.
    private final class Recorder: @unchecked Sendable {
        var events: [CGEvent] = []
        var scheduledDelays: [TimeInterval] = []
    }

    private func makeSynthesizer(
        trusted: Bool,
        recorder: Recorder,
        runScheduled: Bool = true
    ) -> PasteSynthesizer {
        PasteSynthesizer(
            isTrusted: { trusted },
            postEvent: { recorder.events.append($0) },
            schedule: { delay, work in
                recorder.scheduledDelays.append(delay)
                if runScheduled { work() }
            }
        )
    }

    /// Without Accessibility nothing is typed — the caller falls back to
    /// copy-only rather than silently doing nothing at all.
    @Test
    func withoutAccessibilityNothingIsPosted() {
        let recorder = Recorder()
        let synthesizer = makeSynthesizer(trusted: false, recorder: recorder)

        #expect(synthesizer.pasteToFrontmostApp() == false)
        #expect(synthesizer.canPaste == false)
        #expect(recorder.events.isEmpty)
        #expect(recorder.scheduledDelays.isEmpty)
    }

    /// With the grant it sends exactly one ⌘V: key down then key up, command
    /// held for both.
    @Test
    func withAccessibilityItSendsCommandVOnce() {
        let recorder = Recorder()
        let synthesizer = makeSynthesizer(trusted: true, recorder: recorder)

        #expect(synthesizer.pasteToFrontmostApp())
        #expect(recorder.events.count == 2)

        let downs = recorder.events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        #expect(downs == [9, 9])
        #expect(recorder.events.allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(recorder.events[0].type == .keyDown)
        #expect(recorder.events[1].type == .keyUp)
    }

    /// The pasteboard is written a beat before the keystroke, and that beat is
    /// long enough for something else to write over it — Universal Clipboard
    /// handing over a phone's clipboard, another manager, an app that copies
    /// on selection. Pasting anyway put content in the document that the user
    /// had not picked.
    @Test
    func aClipOvertakenBeforeTheKeystrokeIsNotPasted() {
        let recorder = Recorder()
        let synthesizer = makeSynthesizer(trusted: true, recorder: recorder)

        #expect(synthesizer.pasteToFrontmostApp(isStillCurrent: { false }))

        #expect(recorder.scheduledDelays.count == 1)
        #expect(recorder.events.isEmpty)
    }

    /// The keystroke waits a beat so the pasteboard write and the picker
    /// dismissal land first.
    @Test
    func theKeystrokeIsDelayedNotImmediate() {
        let recorder = Recorder()
        let synthesizer = makeSynthesizer(trusted: true, recorder: recorder, runScheduled: false)

        synthesizer.pasteToFrontmostApp(after: 0.25)

        #expect(recorder.scheduledDelays == [0.25])
        // Nothing posted until the scheduled work actually runs.
        #expect(recorder.events.isEmpty)
    }
}
