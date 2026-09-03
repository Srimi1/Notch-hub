import AppKit
import NotchHubSafeFeatures
import OSLog
import SwiftUI

@MainActor
private final class LiteNotchPanel: NSPanel {
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

@MainActor
private struct LiteStatusButton: View {
    let model: SafeNotchPresentationModel
    let onHover: @MainActor (Bool) -> Void
    let onActivate: @MainActor () -> Void

    var body: some View {
        Button(action: onActivate) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                if needsAttention {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.black, lineWidth: 1))
                        .offset(x: 3, y: -2)
                }
            }
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("NotchHub Lite")
        .accessibilityValue(needsAttention ? "Needs attention" : "Ready")
        .help("NotchHub Lite — select for details")
    }

    private var needsAttention: Bool {
        model.workspace.dashboard.lastError != nil ||
            model.workspace.clipboard.lastIssue != nil ||
            model.workspace.focus.state == .completed
    }
}

@MainActor
final class LiteApplicationController: NSObject, NSApplicationDelegate {
    let model = SafeNotchPresentationModel()

    private var statusItem: NSStatusItem?
    private var panel: LiteNotchPanel?
    private var dismissTask: Task<Void, Never>?
    private var panelHovered = false
    private var statusHovered = false

    private static let logger = Logger(subsystem: "com.notchhub.v1.lite", category: "Application")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.workspace.start()
        installMainMenu()
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

    func applicationWillTerminate(_ notification: Notification) {
        dismissTask?.cancel()
        model.workspace.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "NotchHub Lite")
        let appItem = NSMenuItem(title: "NotchHub Lite", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "NotchHub Lite")
        let quitItem = NSMenuItem(
            title: "Quit NotchHub Lite",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else {
            Self.logger.error("The system did not provide a status-item button")
            return
        }
        let root = LiteStatusButton(
            model: model,
            onHover: { [weak self] hovering in self?.statusHoverChanged(hovering) },
            onActivate: { [weak self] in self?.toggleDetail() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        statusItem = item
    }

    private func installPanel() {
        guard panel == nil, let screen = preferredScreen() else { return }
        let panel = LiteNotchPanel(contentRect: panelFrame(on: screen))
        panel.contentView = NSHostingView(
            rootView: SafeNotchPanelView(
                model: model,
                onHover: { [weak self] hovering in self?.panelHoverChanged(hovering) },
                onDismiss: { [weak self] in self?.dismissPanel() }
            )
        )
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
            scheduleDismissIfCompact()
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        panelHovered = hovering
        if hovering {
            cancelDismiss()
        } else {
            scheduleDismissIfCompact()
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

    private func scheduleDismissIfCompact() {
        guard model.tier == .compact else { return }
        cancelDismiss()
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(260))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Compact-panel dismissal wait failed")
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
            panel.animator().setFrame(target, display: true)
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
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        return screen.safeAreaInsets.top > 0 &&
            leftWidth > 0 &&
            rightWidth > 0 &&
            leftWidth + rightWidth < screen.frame.width
    }

    @objc private func screenParametersChanged() {
        if panel == nil {
            installPanel()
        }
        refreshPanelLayout()
    }
}
