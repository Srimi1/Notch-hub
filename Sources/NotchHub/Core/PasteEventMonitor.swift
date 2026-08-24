import AppKit

/// Watches for ⌘V anywhere on the system while a copy popup is showing, so the
/// popup can dismiss the moment its content is actually used.
///
/// Global key monitoring only delivers events to apps the user has trusted for
/// Accessibility. NotchHub never requests that — `start()` reads
/// `AXIsProcessTrusted()` (the non-prompting check) and quietly does nothing
/// when the grant is absent, so the popup falls back to its timed dismissal.
/// The monitor exists only while a popup is on screen: installed by `start()`,
/// torn down by `stop()`, never long-lived.
@MainActor
final class PasteEventMonitor {

    var onPaste: (() -> Void)?

    private var monitor: Any?
    private let isTrusted: () -> Bool
    private let installMonitor: (@escaping (NSEvent) -> Void) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        installMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.isTrusted = isTrusted
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil, isTrusted() else { return }
        monitor = installMonitor { [weak self] event in
            guard Self.isCommandV(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else { return }
            Task { @MainActor [weak self] in self?.onPaste?() }
        }
    }

    func stop() {
        if let monitor {
            removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Plain ⌘V and nothing else: ⇧⌘V (paste-and-match-style) and friends are
    /// still pastes, so any combination that includes ⌘ with a lone "v" counts,
    /// but ⌃V or a bare "v" does not.
    static func isCommandV(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard characters?.lowercased() == "v" else { return false }
        return modifiers.intersection(.deviceIndependentFlagsMask).contains(.command)
    }
}
