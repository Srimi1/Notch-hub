import AppKit

/// Recognises two quick taps of a single key as a gesture, without taking that
/// key away from anything else.
///
/// The trigger is a plain letter, which means the same key press is also
/// ordinary typing. A global monitor cannot swallow events — the letters the
/// user typed still land wherever they were typing — so the whole question is
/// when *not* to fire. Two rules do that work:
///
/// - Nothing may come between the taps. Any other key, or any modifier, ends
///   the pair.
/// - The first tap has to follow a pause. Words with a double letter in them
///   are the obvious hazard ("announce", "running"), and in every one of them
///   the first of the pair arrives hard on the heels of another keystroke.
///
/// What is left is a deliberate gesture: stop typing, tap twice.
enum KeyDoubleTap {

    /// `kVK_ANSI_N`, positional and identical on every keyboard layout.
    nonisolated static let keyCodeN: UInt16 = 45

    /// How close together the two taps have to be.
    nonisolated static let tapWindow: TimeInterval = 0.3

    /// How long the keyboard has to have been quiet before a tap can open a
    /// pair. Long enough that no rhythm of real typing reaches it.
    nonisolated static let typingIdle: TimeInterval = 1.0

    struct State: Equatable, Sendable {
        /// When the tap waiting for its partner arrived.
        var pendingTapTime: TimeInterval?
        /// Whether that tap followed a long enough pause to count.
        var pendingTapQualified = false
        /// The last key press of any kind, the gesture's own taps included.
        var lastKeystrokeTime: TimeInterval?

        init() {}
    }

    /// Feed every key press. Returns the state to keep and whether the gesture
    /// just completed.
    nonisolated static func evaluate(
        state: State,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        targetKeyCode: UInt16 = keyCodeN
    ) -> (state: State, fired: Bool) {
        var next = state
        next.lastKeystrokeTime = timestamp

        // A modified press is a shortcut or a capital letter, not the gesture —
        // and it breaks any pair in progress.
        let isBareTargetKey = keyCode == targetKeyCode
            && modifiers.isDisjoint(with: .deviceIndependentFlagsMask)
        guard isBareTargetKey else {
            next.pendingTapTime = nil
            next.pendingTapQualified = false
            return (next, false)
        }

        if let pending = state.pendingTapTime,
           state.pendingTapQualified,
           timestamp - pending <= tapWindow {
            // Completing the pair consumes it, so a third tap starts over
            // rather than firing again.
            next.pendingTapTime = nil
            next.pendingTapQualified = false
            return (next, true)
        }

        next.pendingTapTime = timestamp
        next.pendingTapQualified = state.lastKeystrokeTime.map {
            timestamp - $0 >= typingIdle
        } ?? true
        return (next, false)
    }
}

/// Watches the whole system for the double-tap and reports it.
///
/// Global key monitoring only reaches apps trusted for Accessibility. NotchHub
/// never asks for that here — `start()` uses the non-prompting check and
/// quietly does nothing without the grant, exactly like `PasteEventMonitor`.
@MainActor
final class KeyDoubleTapMonitor {

    var onDoubleTap: (() -> Void)?

    private var monitor: Any?
    private var state = KeyDoubleTap.State()
    private let targetKeyCode: UInt16
    private let isTrusted: () -> Bool
    private let installMonitor: (@escaping (NSEvent) -> Void) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        targetKeyCode: UInt16 = KeyDoubleTap.keyCodeN,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        installMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.targetKeyCode = targetKeyCode
        self.isTrusted = isTrusted
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil, isTrusted() else { return }
        monitor = installMonitor { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp)
            }
        }
    }

    func stop() {
        if let monitor {
            removeMonitor(monitor)
        }
        monitor = nil
        // A half-finished pair must not survive to pair up with a tap from
        // whenever the monitor next runs.
        state = KeyDoubleTap.State()
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        let result = KeyDoubleTap.evaluate(
            state: state,
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            targetKeyCode: targetKeyCode
        )
        state = result.state
        if result.fired { onDoubleTap?() }
    }
}
