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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
        .help("NotchHub Lite — click to pin the ribbon")
    }

    private var needsAttention: Bool {
        model.workspace.dashboard.lastError != nil
            || model.workspace.clipboard.lastIssue != nil
            || model.workspace.focus.state == .completed
    }
}

@MainActor
final class LiteApplicationController: NSObject, NSApplicationDelegate {
    let model = SafeNotchPresentationModel()

    private var statusItem: NSStatusItem?
    private var panel: LiteNotchPanel?
    private var geometry: NotchOverlayGeometry?
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var panelHoverGate = NotchHoverGate()
    private var statusHovered = false
    private var isPinned = false
    private var frameGeneration = 0

    private static let logger = Logger(subsystem: "com.notchhub.v1.lite", category: "Application")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.workspace.start()
        installMainMenu()
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

    func applicationWillTerminate(_ notification: Notification) {
        expandTask?.cancel()
        collapseTask?.cancel()
        model.workspace.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
            onActivate: { [weak self] in self?.togglePinnedRibbon() }
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
        let geometry = NotchOverlayGeometry(screen: screen)
        let panel = LiteNotchPanel(contentRect: panelFrame(on: screen, geometry: geometry))
        panel.contentView = hostedContent(geometry: geometry)
        self.geometry = geometry
        self.panel = panel
    }

    private func hostedContent(geometry: NotchOverlayGeometry) -> NSHostingView<SafeNotchPanelView> {
        NSHostingView(
            rootView: SafeNotchPanelView(
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
            showsWings: model.workspace.focus.state != .idle
        )
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
