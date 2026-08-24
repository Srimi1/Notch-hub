import AppKit
import Combine
import SwiftUI

/// Wires together the notch geometry, the overlay panel, the SwiftUI content,
/// and hover handling. Owns the expand/collapse window-frame animation: the
/// window is only ever as large as its visible content, which keeps mouse
/// handling simple (no large transparent dead-zone swallowing clicks).
@MainActor
final class NotchWindowController {

    private var panel: NotchPanel
    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var geometry: NotchGeometry
    private weak var hoverView: HoverView?
    private weak var hostingView: NSHostingView<NotchContainerView>?

    static let expandedSize = CGSize(
        width: NotchTheme.expandedWidth,
        height: NotchTheme.expandedHeight
    )

    /// The transient popup tier: bigger than the pill, far smaller than the
    /// dashboard — the "medium black box" the copy HUD lives in.
    static let hudSize = CGSize(width: 520, height: 104)

    /// The three window sizes the overlay animates between.
    enum Tier: Equatable {
        case collapsed
        case hud
        case expanded
    }

    /// Fails when no display is attached yet.
    ///
    /// `NSScreen.notchScreen` already falls back to `main` and then to the
    /// first screen, so it returns nil *precisely* when `NSScreen.screens` is
    /// empty — the previous `?? NSScreen.screens[0]` fallback subscripted that
    /// same empty array and trapped. A headless launch is reachable in practice
    /// because NotchHub offers Launch at Login, which can fire before the
    /// displays wake.
    init?(preferences: ModulePreferences, services: ServiceHub) {
        guard let screen = NSScreen.notchScreen else { return nil }
        self.viewModel = NotchViewModel(preferences: preferences, services: services)
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
        hoverView.hasPhysicalNotch = geometry.hasPhysicalNotch
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
        Publishers.CombineLatest(viewModel.$isExpanded, viewModel.$hudContent)
            .map { expanded, hud -> Tier in
                if expanded { return .expanded }
                return hud == nil ? .collapsed : .hud
            }
            .removeDuplicates()
            .sink { [weak self] tier in
                self?.animateFrame(tier: tier)
            }
            .store(in: &cancellables)

        // Grow/shrink the collapsed pill when a live activity appears, but only
        // while collapsed — the other tiers already own the frame.
        viewModel.$showCollapsedWings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.viewModel.isExpanded,
                      self.viewModel.hudContent == nil else { return }
                self.animateFrame(tier: .collapsed)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func show() {
        panel.setFrame(collapsedFrame(), display: true)
        panel.claimInteractionLayer()
        panel.yieldToPeerOverlays()
    }

    func toggle() {
        viewModel.toggle()
    }

    func collapse() {
        viewModel.collapse()
    }

    /// Recompute geometry for the current active screen (display changes).
    func repositionForActiveScreen() {
        guard let screen = NSScreen.notchScreen else { return }
        geometry = NotchGeometry(screen: screen)
        viewModel.notchSize = geometry.notchSize
        // Moving between a notched laptop display and an external monitor
        // changes how the overlay must be drawn, not just where it sits.
        hoverView?.hasPhysicalNotch = geometry.hasPhysicalNotch
        let tier: Tier = viewModel.isExpanded ? .expanded : (viewModel.hudContent == nil ? .collapsed : .hud)
        animateFrame(tier: tier)
    }

    // MARK: - Frame animation

    private func animateFrame(tier: Tier) {
        let target: NSRect
        switch tier {
        case .collapsed: target = collapsedFrame()
        case .hud: target = hudFrame()
        case .expanded: target = expandedFrame()
        }
        // The popup takes clicks and drags, so it needs the interaction layer
        // exactly like the dashboard does.
        if tier != .collapsed { panel.claimInteractionLayer() }
        hoverView?.bottomRadius = switch tier {
        case .collapsed: 10
        case .hud: 18
        case .expanded: 24
        }
        resizeContent(to: target.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard tier == .collapsed else { return }
            Task { @MainActor [weak self] in self?.panel.yieldToPeerOverlays() }
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

    private func hudFrame() -> NSRect {
        let size = CGSize(
            width: min(Self.hudSize.width, max(0, geometry.screen.frame.width - 40)),
            height: Self.hudSize.height
        )
        return Self.topCentered(size: size, on: geometry.screen)
    }

    private func expandedFrame() -> NSRect {
        let size = Self.expandedSize(forScreenWidth: geometry.screen.frame.width)
        return Self.topCentered(
            size: size,
            on: geometry.screen
        )
    }

    static func expandedSize(forScreenWidth screenWidth: CGFloat) -> CGSize {
        CGSize(
            width: min(expandedSize.width, max(0, screenWidth - 40)),
            height: expandedSize.height
        )
    }

    private static func topCentered(size: CGSize, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
