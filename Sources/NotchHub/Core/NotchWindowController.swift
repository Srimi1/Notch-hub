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
    /// Identifies the in-flight frame animation, so a completion that has been
    /// overtaken by a newer one does nothing.
    private var frameGeneration = 0
    /// Fallback that settles the frame if the animation's own completion is late
    /// or never arrives — see `animateFrame`.
    private var pendingSettle: DispatchWorkItem?

    static let expandedSize = CGSize(
        width: NotchTheme.expandedWidth,
        height: NotchTheme.expandedHeight
    )

    /// The transient popup tier: bigger than the pill, far smaller than the
    /// dashboard — the "medium black box" the copy HUD lives in.
    static let hudSize = CGSize(width: 520, height: 104)

    /// The clipboard picker: taller than the popup, because it lists the whole
    /// history rather than the last few.
    static let pickerSize = CGSize(width: 560, height: 360)

    /// The window sizes the overlay animates between.
    enum Tier: Equatable {
        case collapsed
        case hud
        case picker
        case expanded
    }

    /// Which window size a given presentation state needs. Pure so the mapping
    /// is testable without a window.
    static func tier(isExpanded: Bool, hudContent: HudContent?) -> Tier {
        if isExpanded { return .expanded }
        switch hudContent {
        case .none: return .collapsed
        case .clipPicker: return .picker
        case .clip, .peek, .charging: return .hud
        }
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
            .map { expanded, hud in Self.tier(isExpanded: expanded, hudContent: hud) }
            .removeDuplicates()
            .sink { [weak self] tier in
                self?.animateFrame(tier: tier)
            }
            .store(in: &cancellables)

        // Losing the keyboard closes the picker.
        //
        // The picker is opaque, sits at status-bar level across every Space,
        // and has no auto-dismiss — it waits for a choice. When the user makes
        // that choice by clicking back into their document instead, nothing was
        // left to close it: the panel simply stayed on screen over the top of
        // the frontmost window, swallowing clicks, with Escape no longer
        // reaching it because local key monitors only see NotchHub's own events.
        NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.viewModel.hudContent == .clipPicker else { return }
                // The keyboard has already gone somewhere the user chose, so
                // drop the borrow rather than dragging them back to it.
                self.panel.forgetBorrowedKeyFocus()
                self.viewModel.dismissHUD()
            }
            .store(in: &cancellables)

        // Grow/shrink the collapsed pill when a live activity appears, but only
        // while collapsed — the other tiers already own the frame.
        viewModel.$showCollapsedWings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] wings in
                guard let self, !self.viewModel.isExpanded,
                      self.viewModel.hudContent == nil else { return }
                // Size the pill from the value being published, not from the
                // property: @Published emits in willSet, so re-reading it here
                // returns the *previous* state. The frame ran one transition
                // behind — widening for wings just as they went away, which
                // left an oversized pill with nothing in it.
                self.animateFrame(tier: .collapsed, showWings: wings)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func show() {
        panel.setFrame(collapsedFrame(showWings: viewModel.showCollapsedWings), display: true)
        panel.claimInteractionLayer()
        panel.yieldToPeerOverlays()
        // A cursor already resting over the notch at launch produces no
        // mouseEntered until it moves, so read the real pointer position once
        // the panel is on screen.
        hoverView?.syncHoverState()
    }

    /// Re-read hover from the pointer's true position.
    ///
    /// Used after moments the tracking area's enter/exit can miss — app
    /// activation, a display change, wake — where a cursor already sitting over
    /// the notch would otherwise never register until it moved.
    func reconcileHover() {
        hoverView?.syncHoverState()
    }

    func toggle() {
        viewModel.toggle()
    }

    func collapse() {
        viewModel.collapse()
    }

    /// Drop the clipboard picker out of the notch. Driven by the global
    /// shortcut, which can fire while any app is frontmost.
    func showClipPicker() {
        viewModel.toggleClipPicker()
    }

    /// Recompute geometry for the current active screen (display changes).
    func repositionForActiveScreen() {
        guard let screen = NSScreen.notchScreen else { return }
        geometry = NotchGeometry(screen: screen)
        viewModel.notchSize = geometry.notchSize
        // Moving between a notched laptop display and an external monitor
        // changes how the overlay must be drawn, not just where it sits.
        hoverView?.hasPhysicalNotch = geometry.hasPhysicalNotch
        animateFrame(
            tier: Self.tier(isExpanded: viewModel.isExpanded, hudContent: viewModel.hudContent)
        )
    }

    // MARK: - Frame animation

    private func animateFrame(tier: Tier, showWings: Bool? = nil) {
        let target = frame(for: tier, showWings: showWings)
        applyChrome(for: tier)
        // The content view is laid out from the window's bottom-left, and the
        // window's top edge is welded to the top of the screen — so content
        // taller than the window does not overhang downwards, it runs off the
        // top of the display where it cannot be seen. Grow the content first so
        // it is ready when the window reaches it, but shrink it only once the
        // window has, and never below the window in between.
        //
        // The generation guard covers a retarget: if a newer, larger frame is
        // already on its way when a shrink completes, honouring the stale
        // completion would cut the content out from under it.
        frameGeneration += 1
        let generation = frameGeneration
        let grows = target.width >= panel.frame.width && target.height >= panel.frame.height
        if grows { resizeContent(to: target.size) }
        // Enter and exit events are not to be trusted while the frame moves;
        // the settle below reconciles from the pointer's real position.
        hoverView?.isFrameAnimating = true

        let duration = NotchMotion.currentDuration

        // A fallback in case the animation's own completion is late or never
        // fires (display sleep or disconnect mid-move): the frame still settles,
        // so the hover gate cannot stay stuck true. Whichever runs first settles;
        // the other is cancelled or no-ops on the generation guard.
        let settle = DispatchWorkItem { [weak self] in
            self?.settleFrame(generation: generation, target: target, tier: tier)
        }
        pendingSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: settle)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = NotchMotion.timingFunction
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.settleFrame(generation: generation, target: target, tier: tier)
            }
        }
    }

    /// Finish a frame animation: resize content to the final size, drop the
    /// hover gate, and reconcile hover. Guarded by `frameGeneration` so a stale
    /// completion (a newer, larger frame already on its way) does not cut the
    /// content out from under it. Idempotent, so the animation completion and
    /// the fallback timer can both call it.
    private func settleFrame(generation: Int, target: NSRect, tier: Tier) {
        guard frameGeneration == generation else { return }
        pendingSettle?.cancel()
        pendingSettle = nil
        resizeContent(to: target.size)
        hoverView?.endFrameAnimation()
        if tier == .collapsed { panel.yieldToPeerOverlays() }
    }

    private func frame(for tier: Tier, showWings: Bool?) -> NSRect {
        switch tier {
        case .collapsed: collapsedFrame(showWings: showWings ?? viewModel.showCollapsedWings)
        case .hud: hudFrame()
        case .picker: pickerFrame()
        case .expanded: expandedFrame()
        }
    }

    /// Interaction, keyboard, and corner rounding for a tier.
    private func applyChrome(for tier: Tier) {
        // The popup takes clicks and drags, so it needs the interaction layer
        // exactly like the dashboard does.
        if tier != .collapsed { panel.claimInteractionLayer() }
        // The picker is keyboard-driven, so it borrows key status the other
        // tiers do not need — and gives it straight back on the way out. The
        // panel is non-activating, so the app the user was typing in stays
        // frontmost throughout; but frontmost is not the same as key, and while
        // the panel held the keyboard the synthesized ⌘V was delivered to the
        // notch instead of to their document.
        if tier == .picker { panel.takeKeyFocus() } else { panel.releaseKeyFocus() }
        hoverView?.bottomRadius = switch tier {
        case .collapsed: 10
        case .hud: 18
        case .picker, .expanded: 24
        }
    }

    private func resizeContent(to size: CGSize) {
        let contentFrame = NSRect(origin: .zero, size: size)
        hoverView?.frame = contentFrame
        hostingView?.frame = contentFrame
    }

    // MARK: - Frames (top-centered on the active screen)

    private func collapsedFrame(showWings: Bool) -> NSRect {
        var size = geometry.notchSize
        size.width = Self.collapsedWidth(
            notchWidth: size.width,
            showWings: showWings,
            wingWidth: viewModel.collapsedWingWidth,
            wingPadding: viewModel.collapsedWingPadding
        )
        return Self.topCentered(size: size, on: geometry.screen)
    }

    /// Window width for the collapsed pill. Symmetric wings keep the black
    /// body centered over the physical camera housing, and each wing needs its
    /// outer padding as well as its own width — budgeting only the wing slid
    /// the last few characters of the clock and the activity label under the
    /// housing, where they cannot be read.
    static func collapsedWidth(
        notchWidth: CGFloat,
        showWings: Bool,
        wingWidth: CGFloat,
        wingPadding: CGFloat
    ) -> CGFloat {
        guard showWings else { return notchWidth }
        return notchWidth + (wingWidth + wingPadding) * 2
    }

    private func hudFrame() -> NSRect {
        let size = CGSize(
            width: min(Self.hudSize.width, max(0, geometry.screen.frame.width - 40)),
            height: Self.hudSize.height
        )
        return Self.topCentered(size: size, on: geometry.screen)
    }

    private func pickerFrame() -> NSRect {
        let size = CGSize(
            width: min(Self.pickerSize.width, max(0, geometry.screen.frame.width - 40)),
            height: min(Self.pickerSize.height, max(0, geometry.screen.frame.height - 80))
        )
        return Self.topCentered(size: size, on: geometry.screen)
    }

    private func expandedFrame() -> NSRect {
        let size = Self.expandedSize(
            forScreenWidth: geometry.screen.frame.width,
            notchHeight: geometry.notchSize.height
        )
        return Self.topCentered(
            size: size,
            on: geometry.screen
        )
    }

    static func expandedSize(
        forScreenWidth screenWidth: CGFloat,
        notchHeight: CGFloat = NotchTheme.navigationHeight
    ) -> CGSize {
        CGSize(
            width: min(expandedSize.width, max(0, screenWidth - 40)),
            height: NotchTheme.expandedHeight(notchHeight: notchHeight)
        )
    }

    private static func topCentered(size: CGSize, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
