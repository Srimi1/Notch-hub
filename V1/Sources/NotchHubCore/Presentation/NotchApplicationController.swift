import AppKit
import NotchHubSafeFeatures
import SwiftUI

public struct StatusMeterButton: View {
    private let model: AppPresentationModel
    private let onHover: @MainActor (Bool) -> Void
    private let onActivate: @MainActor () -> Void

    public init(
        model: AppPresentationModel,
        onHover: @escaping @MainActor (Bool) -> Void,
        onActivate: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.onHover = onHover
        self.onActivate = onActivate
    }

    public var body: some View {
        Button(action: onActivate) {
            ZStack(alignment: .topTrailing) {
                UsageRing(value: model.highestUtilization, diameter: 18)
                if model.hasAttention {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.black, lineWidth: 1))
                        .offset(x: 2, y: -2)
                }
            }
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("NotchHub")
        .accessibilityValue(accessibilityValue)
        .help("NotchHub — click to pin the ribbon")
    }

    private var accessibilityValue: String {
        if model.hasAttention { return "Needs attention" }
        guard let value = model.highestUtilization else { return "Checking providers" }
        return "Highest provider usage \(Int(value.rounded())) percent"
    }
}

@MainActor
private final class AdaptiveNotchPanel: NSPanel {
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
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the top-edge ribbon. The physical notch is the primary hover target;
/// the menu-bar meter is retained as a secondary pin/unpin command.
@MainActor
public final class NotchHubApplicationController: NSObject, NSApplicationDelegate {
    public let model: AppPresentationModel

    private var statusItem: NSStatusItem?
    private var panel: AdaptiveNotchPanel?
    private var geometry: NotchOverlayGeometry?
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var panelHoverGate = NotchHoverGate()
    private var statusHovered = false
    private var isPinned = false
    private var frameGeneration = 0

    public init(edition: ApplicationEdition) {
        self.model = AppPresentationModel(edition: edition)
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.safeFeatures.start()
        installStatusItem()
        installPanel()
        model.setLayoutChangeHandler { [weak self] in self?.refreshPanelLayout() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        panel?.orderFrontRegardless()
        panel?.orderBack(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        expandTask?.cancel()
        collapseTask?.cancel()
        model.safeFeatures.stop()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else { return }
        let root = StatusMeterButton(
            model: model,
            onHover: { [weak self] hovering in self?.statusHoverChanged(hovering) },
            onActivate: { [weak self] in self?.togglePinnedRibbon() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        statusItem = item
    }

    private func installPanel() {
        guard panel == nil, let screen = preferredScreen() else { return }
        let geometry = NotchOverlayGeometry(screen: screen)
        let panel = AdaptiveNotchPanel(contentRect: panelFrame(on: screen, geometry: geometry))
        panel.contentView = hostedContent(geometry: geometry)
        self.geometry = geometry
        self.panel = panel
    }

    private func hostedContent(geometry: NotchOverlayGeometry) -> NSHostingView<NotchPanelView> {
        NSHostingView(
            rootView: NotchPanelView(
                model: model,
                geometry: geometry,
                onHover: { [weak self] hovering in self?.panelHoverChanged(hovering) },
                onDismiss: { [weak self] in self?.collapseRibbon() }
            )
        )
    }

    private func statusHoverChanged(_ hovering: Bool) {
        statusHovered = hovering
        if hovering {
            scheduleExpansion()
        } else {
            scheduleCollapse()
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        guard let accepted = panelHoverGate.handleTransient(hovering) else { return }
        applyPanelHover(accepted)
    }

    private func applyPanelHover(_ hovering: Bool) {
        if hovering {
            scheduleExpansion()
        } else {
            scheduleCollapse()
        }
    }

    private func togglePinnedRibbon() {
        cancelTransitions()
        if isPinned, model.tier == .detail {
            collapseRibbon()
        } else {
            isPinned = true
            model.showDetail()
            panel?.orderFrontRegardless()
        }
    }

    private func scheduleExpansion() {
        collapseTask?.cancel()
        guard model.tier == .compact else { return }
        expandTask?.cancel()
        expandTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self, panelHoverGate.isHovered || statusHovered else { return }
            model.showDetail()
        }
    }

    private func scheduleCollapse() {
        expandTask?.cancel()
        guard !isPinned, model.tier == .detail else { return }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, !panelHoverGate.isHovered, !statusHovered, !pointerIsInsidePanel else {
                return
            }
            collapseRibbon()
        }
    }

    private var pointerIsInsidePanel: Bool {
        panel?.frame.contains(NSEvent.mouseLocation) == true
    }

    private func collapseRibbon() {
        isPinned = false
        cancelTransitions()
        model.showCompact()
        if model.tier == .compact {
            panel?.orderBack(nil)
        }
    }

    private func cancelTransitions() {
        expandTask?.cancel()
        collapseTask?.cancel()
        expandTask = nil
        collapseTask = nil
    }

    private func refreshPanelLayout() {
        guard let panel, let screen = preferredScreen() else { return }
        let newGeometry = NotchOverlayGeometry(screen: screen)
        if geometry != newGeometry {
            geometry = newGeometry
            panel.contentView = hostedContent(geometry: newGeometry)
        }
        let target = panelFrame(on: screen, geometry: newGeometry)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.18
        frameGeneration += 1
        let generation = frameGeneration
        panelHoverGate.beginFrameAnimation()
        if model.tier == .detail {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, frameGeneration == generation else { return }
                let reconciled = panelHoverGate.finishFrameAnimation(
                    pointerIsInside: pointerIsInsidePanel
                )
                if let reconciled {
                    applyPanelHover(reconciled)
                }
                if model.tier == .compact {
                    panel.orderBack(nil)
                }
            }
        }
    }

    private func panelFrame(on screen: NSScreen, geometry: NotchOverlayGeometry) -> NSRect {
        NotchOverlayFramePolicy.frame(
            in: screen.frame,
            geometry: geometry,
            isExpanded: model.tier == .detail,
            showsWings: showsActivityWings
        )
    }

    private var showsActivityWings: Bool {
        model.hasAttention
            || model.highestUtilization != nil
            || model.activeSessionCount > 0
            || model.safeFeatures.focus.state != .idle
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: Self.hasPhysicalNotch) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        NotchOverlayGeometry(screen: screen).hasPhysicalNotch
    }

    @objc private func screenParametersChanged() {
        if panel == nil { installPanel() }
        refreshPanelLayout()
    }
}
