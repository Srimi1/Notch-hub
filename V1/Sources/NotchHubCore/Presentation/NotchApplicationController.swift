import AppKit
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
        .help("NotchHub — select for details")
    }

    private var accessibilityValue: String {
        if model.hasAttention {
            return "Needs attention"
        }
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

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// AppKit lifecycle and overlay ownership shared by both editions.
@MainActor
public final class NotchHubApplicationController: NSObject, NSApplicationDelegate {
    public let model: AppPresentationModel

    private var statusItem: NSStatusItem?
    private var panel: AdaptiveNotchPanel?
    private var dismissTask: Task<Void, Never>?
    private var panelHovered = false
    private var statusHovered = false

    public init(edition: ApplicationEdition) {
        self.model = AppPresentationModel(edition: edition)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installPanel()
        model.setLayoutChangeHandler { [weak self] in
            self?.refreshPanelLayout()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dismissTask?.cancel()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else { return }
        let root = StatusMeterButton(
            model: model,
            onHover: { [weak self] hovering in self?.statusHoverChanged(hovering) },
            onActivate: { [weak self] in self?.toggleDetail() }
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
        guard panel == nil else { return }
        guard let screen = preferredScreen() else { return }
        let frame = panelFrame(on: screen)
        let panel = AdaptiveNotchPanel(contentRect: frame)
        let root = NotchPanelView(
            model: model,
            onHover: { [weak self] hovering in self?.panelHoverChanged(hovering) },
            onDismiss: { [weak self] in self?.dismissPanel() }
        )
        panel.contentView = NSHostingView(rootView: root)
        self.panel = panel
    }

    private func statusHoverChanged(_ hovering: Bool) {
        statusHovered = hovering
        if hovering {
            cancelDismiss()
            if panel?.isVisible != true {
                model.showCompact()
                showPanel()
            }
        } else {
            scheduleDismissIfUnpinned()
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        panelHovered = hovering
        if hovering {
            cancelDismiss()
        } else {
            scheduleDismissIfUnpinned()
        }
    }

    private func toggleDetail() {
        cancelDismiss()
        if panel?.isVisible == true, model.tier == .detail {
            dismissPanel()
        } else {
            model.showDetail()
            showPanel()
        }
    }

    private func showPanel() {
        if panel == nil {
            installPanel()
        }
        guard let panel else { return }
        refreshPanelLayout()
        panel.orderFrontRegardless()
        if model.tier == .detail {
            panel.makeKey()
        }
    }

    private func dismissPanel() {
        cancelDismiss()
        panel?.resignKey()
        panel?.orderOut(nil)
        model.showCompact()
    }

    private func scheduleDismissIfUnpinned() {
        guard model.tier == .compact else { return }
        cancelDismiss()
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(260))
            } catch {
                return
            }
            guard let self, !self.panelHovered, !self.statusHovered else { return }
            panel?.orderOut(nil)
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func refreshPanelLayout() {
        guard let panel, let screen = preferredScreen() else { return }
        let target = panelFrame(on: screen)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
        if model.pendingApproval != nil, !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let requested = model.panelMetrics
        let width = min(requested.width, max(320, screen.frame.width - 32))
        let height = min(requested.height, max(160, screen.frame.height - 64))
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: Self.hasPhysicalNotch) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        return screen.safeAreaInsets.top > 0 && left > 0 && right > 0 && left + right < screen.frame.width
    }

    @objc private func screenParametersChanged() {
        if panel == nil {
            installPanel()
        }
        refreshPanelLayout()
    }
}
