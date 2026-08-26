import AppKit

/// Hosts the SwiftUI content and reports hover enter/exit via a tracking area
/// that automatically follows the view's bounds (`.inVisibleRect`), so it stays
/// correct as the overlay window resizes between collapsed and expanded states.
final class HoverView: NSView {

    var onHoverChange: ((Bool) -> Void)?
    var bottomRadius: CGFloat = 10 {
        didSet { needsLayout = true }
    }

    /// Whether the overlay is sitting in a real notch.
    ///
    /// On a notched MacBook the overlay hides inside the camera housing, so an
    /// opaque black rectangle welded to the top edge is exactly right. On an
    /// iMac, a Mac mini, an external display, or a MacBook in clamshell there
    /// is no housing to hide in — the same drawing becomes an opaque black bar
    /// across the middle of the menu bar. There it renders as a rounded,
    /// slightly translucent chip instead, so it reads as an app element.
    var hasPhysicalNotch: Bool = true {
        didSet {
            guard hasPhysicalNotch != oldValue else { return }
            applyBackground()
            needsLayout = true
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private let shapeMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func layout() {
        super.layout()
        updateMask()
        for subview in subviews {
            subview.frame = bounds
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    /// Reconcile the hover flag with where the pointer actually is.
    ///
    /// Called once the window has finished moving, not from `layout()`: every
    /// frame of a resize is a layout pass, and each one asked this question
    /// against a frame still in flight. The answers were wrong often enough to
    /// start a collapse in the middle of an expansion.
    func syncHoverState() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let mouse = convert(windowPoint, from: nil)
        onHoverChange?(bounds.contains(mouse))
    }

    private func configureLayer() {
        wantsLayer = true
        applyBackground()
        layer?.mask = shapeMask
    }

    private func applyBackground() {
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(Self.backgroundAlpha(hasPhysicalNotch: hasPhysicalNotch))
            .cgColor
    }

    /// Fully opaque inside a real notch; slightly translucent elsewhere so the
    /// menu bar shows through instead of being blacked out.
    static func backgroundAlpha(hasPhysicalNotch: Bool) -> CGFloat {
        hasPhysicalNotch ? 1.0 : 0.82
    }

    /// Corner radii for the overlay shape.
    ///
    /// A notch is welded to the top edge of the display, so its top corners sit
    /// behind the bezel and must stay square. Without a notch there is no bezel
    /// to hide them, and square top corners are what make the overlay read as a
    /// bar spanning the menu bar rather than as a floating control.
    static func cornerRadii(
        hasPhysicalNotch: Bool, bottomRadius: CGFloat, in rect: CGRect
    ) -> (top: CGFloat, bottom: CGFloat) {
        let limit = max(0, min(rect.width, rect.height) / 2)
        let bottom = max(0, min(bottomRadius, limit))
        return (top: hasPhysicalNotch ? 0 : bottom, bottom: bottom)
    }

    private func updateMask() {
        let rect = bounds
        let radii = Self.cornerRadii(
            hasPhysicalNotch: hasPhysicalNotch, bottomRadius: bottomRadius, in: rect
        )
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radii.top))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radii.bottom, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radii.bottom, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radii.bottom),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.top))
        if radii.top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radii.top, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + radii.top, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radii.top),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()

        shapeMask.frame = rect
        shapeMask.path = path
    }
}
