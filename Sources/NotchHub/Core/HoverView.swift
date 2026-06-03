import AppKit

/// Hosts the SwiftUI content and reports hover enter/exit via a tracking area
/// that automatically follows the view's bounds (`.inVisibleRect`), so it stays
/// correct as the overlay window resizes between collapsed and expanded states.
final class HoverView: NSView {

    var onHoverChange: ((Bool) -> Void)?
    var bottomRadius: CGFloat = 10 {
        didSet { needsLayout = true }
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
        refreshHoverState()
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

    private func refreshHoverState() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let mouse = convert(windowPoint, from: nil)
        onHoverChange?(bounds.contains(mouse))
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = shapeMask
    }

    private func updateMask() {
        let rect = bounds
        let radius = min(bottomRadius, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        shapeMask.frame = rect
        shapeMask.path = path
    }
}
