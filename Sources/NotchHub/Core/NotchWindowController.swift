import AppKit
import Combine
import SwiftUI

/// Wires together the notch geometry, the overlay panel, the SwiftUI content,
/// and hover handling. Owns the expand/collapse window-frame animation: the
/// window is only ever as large as its visible content, which keeps mouse
/// handling simple (no large transparent dead-zone swallowing clicks).
final class NotchWindowController {

    private var panel: NotchPanel
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var geometry: NotchGeometry
    private weak var hoverView: HoverView?
    private weak var hostingView: NSHostingView<NotchContainerView>?

    /// Size of the expanded dashboard. Wide enough to fit three module toggles
    /// on each side of the notch gap; width is clamped to the screen later.
    private let expandedSize = CGSize(width: 980, height: 112)

    init(preferences: ModulePreferences) {
        self.viewModel = NotchViewModel(preferences: preferences)
        let screen = NSScreen.notchScreen ?? NSScreen.screens[0]
        self.geometry = NotchGeometry(screen: screen)

        let collapsed = Self.topCentered(size: geometry.notchSize, on: geometry.screen)
        self.panel = NotchPanel(contentRect: collapsed)

        installContent()
        viewModel.notchSize = geometry.notchSize
        bind()
    }

    // MARK: - Setup

    private func installContent() {
        let hoverView = HoverView(
            frame: NSRect(origin: .zero, size: panel.frame.size)
        )
        hoverView.autoresizingMask = [.width, .height]
        hoverView.onHoverChange = { [weak self] hovering in
            self?.viewModel.setHover(hovering)
        }

        let root = NotchContainerView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = hoverView.bounds
        hoverView.addSubview(hosting)

        panel.contentView = hoverView
        self.hoverView = hoverView
        self.hostingView = hosting
    }

    private func bind() {
        viewModel.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.animateFrame(expanded: expanded)
            }
            .store(in: &cancellables)

        // Grow/shrink the collapsed pill when a live activity appears, but only
        // while collapsed — expanding already owns the frame.
        viewModel.$showCollapsedWings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.viewModel.isExpanded else { return }
                self.animateFrame(expanded: false)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func show() {
        panel.setFrame(collapsedFrame(), display: true)
        panel.orderFrontRegardless()
    }

    func toggle() {
        viewModel.toggle()
    }

    /// Recompute geometry for the current active screen (display changes).
    func repositionForActiveScreen() {
        guard let screen = NSScreen.notchScreen else { return }
        geometry = NotchGeometry(screen: screen)
        viewModel.notchSize = geometry.notchSize
        animateFrame(expanded: viewModel.isExpanded)
    }

    // MARK: - Frame animation

    private func animateFrame(expanded: Bool) {
        let target = expanded ? expandedFrame() : collapsedFrame()
        hoverView?.bottomRadius = expanded ? 24 : 10
        resizeContent(to: target.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    private func resizeContent(to size: CGSize) {
        let contentFrame = NSRect(origin: .zero, size: size)
        hoverView?.frame = contentFrame
        hostingView?.frame = contentFrame
    }

    // MARK: - Frames (top-centered on the active screen)

    private func collapsedFrame() -> NSRect {
        var size = geometry.notchSize
        if viewModel.showCollapsedWings {
            // Symmetric wings keep the black notch body centered over the
            // physical camera housing.
            size.width += viewModel.collapsedWingWidth * 2
        }
        return Self.topCentered(size: size, on: geometry.screen)
    }

    private func expandedFrame() -> NSRect {
        let maxWidth = geometry.screen.frame.width - 40
        let width = min(expandedSize.width, maxWidth)
        return Self.topCentered(
            size: CGSize(width: width, height: expandedSize.height),
            on: geometry.screen
        )
    }

    private static func topCentered(size: CGSize, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
