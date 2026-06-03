import AppKit

/// A borderless, transparent, always-on-top panel that hosts the notch UI.
///
/// Sits at `.statusBar` window level so it draws above the menu bar (and the
/// physical notch region), is non-activating so interacting with it never
/// steals focus from the frontmost app, and joins all Spaces so the notch is
/// always visible.
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
}
