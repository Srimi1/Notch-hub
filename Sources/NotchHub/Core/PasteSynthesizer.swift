import AppKit

/// Types ⌘V into whichever app the user was working in, so picking a clip from
/// the notch finishes the job instead of leaving them to paste it themselves.
///
/// Posting keyboard events requires Accessibility — the same grant the Focus
/// toggle and the paste monitor need. Without it this quietly reports `false`
/// and the caller falls back to copy-only; it never raises the prompt itself,
/// which belongs to onboarding and the permission rows.
///
/// The notch panel is non-activating (`NotchPanel`), so the frontmost app keeps
/// keyboard focus the whole time and the synthesized keystroke lands where the
/// user expects.
@MainActor
final class PasteSynthesizer {

    /// A beat for the pasteboard write to settle and the picker to get out of
    /// the way before the keystroke lands.
    nonisolated static let defaultDelay: TimeInterval = 0.12

    /// A longer beat for the clip picker, which borrows keyboard focus to read
    /// its digit keys. Handing focus back to the user's app is a round trip
    /// through the window server, and a ⌘V that arrives before it completes is
    /// delivered to the notch instead of to their document.
    nonisolated static let focusHandoffDelay: TimeInterval = 0.25

    /// `kVK_ANSI_V`. Hardcoded rather than imported from Carbon so this file
    /// stays AppKit-only; the virtual key code is positional and identical on
    /// every keyboard layout.
    nonisolated private static let virtualKeyV: CGKeyCode = 9

    private let isTrusted: @Sendable () -> Bool
    private let postEvent: @Sendable (CGEvent) -> Void
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    init(
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        // Posted to the session tap rather than the HID tap. The HID tap sits
        // below the window server's modifier bookkeeping, so a synthesized ⌘V
        // arriving there is merged with whatever the user is physically
        // holding: with the ⌃⌥V shortcut still under their fingers the target
        // app saw ⌘⌃⌥V, which in Finder is Move Item Here — a destructive
        // action from a paste. The session tap carries only the flags set on
        // the event. (If an app is ever found that ignores session-tap events,
        // `.cgAnnotatedSessionEventTap` is the next thing to try.)
        postEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
            = { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
    ) {
        self.isTrusted = isTrusted
        self.postEvent = postEvent
        self.schedule = schedule
    }

    /// Whether a pick can be finished with a real paste, or only copied.
    var canPaste: Bool { isTrusted() }

    /// Sends ⌘V to the frontmost app after `delay`.
    ///
    /// `isStillCurrent` is asked immediately before the keystroke goes out, and
    /// nothing is sent if it says no. The pasteboard is written a beat before
    /// the ⌘V, and that beat is long enough for something else to write over
    /// it — Universal Clipboard handing over an iPhone's clipboard, another
    /// clipboard manager, an app that copies on selection. Pasting anyway put
    /// content in the user's document that they had not chosen.
    ///
    /// Returns whether the keystroke was scheduled: `false` means Accessibility
    /// is missing and the clip is on the pasteboard but nothing was typed.
    @discardableResult
    func pasteToFrontmostApp(
        after delay: TimeInterval = PasteSynthesizer.defaultDelay,
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> Bool {
        guard isTrusted() else { return false }
        // Capture the sink rather than `self` so the scheduled work carries no
        // main-actor state across the hop.
        let post = postEvent
        // The scheduler delivers on the main queue, which is where the check
        // has to run — same assumption `ClipboardService`'s timer makes.
        schedule(delay) {
            MainActor.assumeIsolated {
                guard isStillCurrent() else { return }
                Self.postCommandV(post)
            }
        }
        return true
    }

    nonisolated private static func postCommandV(_ post: @Sendable (CGEvent) -> Void) {
        // A private source keeps the pair out of the shared state the window
        // server merges physical modifiers into, so the event carries exactly
        // the flags set on it here and nothing the user happens to be holding.
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: virtualKeyV,
                keyDown: isDown
            ) else {
                NSLog("NotchHub: could not create ⌘V event (keyDown: \(isDown))")
                return
            }
            event.flags = .maskCommand
            post(event)
        }
    }
}
