import AppKit

/// A borderless, transparent, always-on-top panel that hosts the notch UI.
///
/// Uses status-window level while visible, but cooperates with peer notch/menu
/// utilities: it moves to the front only while expanded and returns to the back
/// of its level when collapsed.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false

        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func claimInteractionLayer() {
        orderFrontRegardless()
    }

    func yieldToPeerOverlays() {
        orderBack(nil)
    }

    // MARK: - Keyboard focus

    /// Who held the keyboard before the picker borrowed it. A window when it was
    /// one of NotchHub's own (Settings, onboarding), an application otherwise.
    private weak var windowToRestore: NSWindow?
    private var appToRestore: NSRunningApplication?
    /// Whether the keyboard was borrowed *by us*. The panel also becomes key
    /// whenever the user simply clicks it, and handing focus away then would
    /// take the app out from under a window they chose themselves.
    private var didBorrowKeyFocus = false

    /// What to do with keyboard focus when the picker goes away. Pure so the
    /// decision is testable without a window server.
    enum KeyFocusHandoff: Equatable {
        /// Another NotchHub window had it — give it straight back.
        case restoreWindow
        /// Give the keyboard back to the app that had it.
        case activate(pid: pid_t)
        /// Nobody to give it back to — step out of the way instead.
        case deactivateApp
        /// We never borrowed it; leave everything alone.
        case nothing
    }

    static func handoff(
        borrowed: Bool,
        hasWindowToRestore: Bool,
        previousPID: pid_t?,
        ownPID: pid_t
    ) -> KeyFocusHandoff {
        guard borrowed else { return .nothing }
        if hasWindowToRestore { return .restoreWindow }
        guard let previousPID, previousPID != ownPID else { return .deactivateApp }
        return .activate(pid: previousPID)
    }

    /// Borrow keyboard focus for the picker.
    ///
    /// A non-activating panel that becomes key takes the *keyboard* without
    /// taking frontmost status — Spotlight's trick — which is what lets plain
    /// digits select a clip. Both what had it are remembered, because taking
    /// focus is only half the job: the frontmost application is the usual
    /// answer, but when Settings is open the window that had the keyboard is
    /// NotchHub's own, and deactivating the app would drop the user somewhere
    /// they never asked to be.
    func takeKeyFocus() {
        guard !didBorrowKeyFocus else { return }
        didBorrowKeyFocus = true
        windowToRestore = NSApp.keyWindow.flatMap { $0 === self ? nil : $0 }
        appToRestore = NSWorkspace.shared.frontmostApplication
        makeKey()
    }

    /// Hand the keyboard back.
    ///
    /// Without this the panel keeps focus after the picker closes: the
    /// synthesized ⌘V lands on the notch, which has no responder for it, so the
    /// clip is copied and nothing is pasted — and everything the user types
    /// afterwards disappears into the collapsed overlay until they click their
    /// document again.
    func releaseKeyFocus() {
        let window = windowToRestore
        let previous = appToRestore
        let borrowed = didBorrowKeyFocus
        forgetBorrowedKeyFocus()

        switch Self.handoff(
            borrowed: borrowed,
            hasWindowToRestore: window?.isVisible == true,
            previousPID: previous?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) {
        case .nothing:
            return
        case .restoreWindow:
            window?.makeKeyAndOrderFront(nil)
        case .deactivateApp:
            NSApp.deactivate()
        case .activate:
            guard let previous, previous.activate(options: []) else {
                NSApp.deactivate()
                return
            }
        }
    }

    /// Drop the borrow without acting on it, for when the keyboard has already
    /// gone somewhere else — the user clicked into another app, or activated
    /// one. Pulling them back to where they were would be worse than doing
    /// nothing.
    func forgetBorrowedKeyFocus() {
        windowToRestore = nil
        appToRestore = nil
        didBorrowKeyFocus = false
    }
}
