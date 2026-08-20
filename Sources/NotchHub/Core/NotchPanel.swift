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
}
