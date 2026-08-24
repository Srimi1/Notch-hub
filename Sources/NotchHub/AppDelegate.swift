import AppKit
import SwiftUI

/// Owns the app lifecycle: spins up the notch overlay window and a menu-bar
/// status item, and re-positions the overlay when the display configuration
/// changes (external monitor connected, resolution change, sleep/wake).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let instanceCoordinator = AppInstanceCoordinator()
    private let preferences = ModulePreferences()
    /// Owned here, not by the notch window, so Settings still has live services
    /// on a launch where no display exists yet — Launch at Login can fire before
    /// the displays wake, and `NotchWindowController.init` returns nil then.
    private let services: ServiceHub
    private let launchAtLogin = LaunchAtLoginController()

    override init() {
        // The hub needs the same preferences object so hiding a module really
        // stops the service behind it, rather than only hiding its tab.
        services = ServiceHub(modulePreferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceCoordinator.shouldContinueLaunching() else {
            NSApplication.shared.terminate(nil)
            return
        }

        // Clear API keys left by the removed credit tracker. No-op after the
        // first run; see `LegacyCredentialCleanup`.
        LegacyCredentialCleanup.runIfNeeded()

        services.startAmbient()
        setUpStatusItem()
        installOverlayIfPossible()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Creates the overlay once a display exists.
    ///
    /// Launch at Login can start NotchHub before any display is awake. Rather
    /// than trap on an empty screen list, the app runs headless — menu bar
    /// only — and installs the overlay when a screen appears.
    private func installOverlayIfPossible() {
        guard notchController == nil else { return }
        guard let controller = NotchWindowController(preferences: preferences, services: services) else {
            NSLog("NotchHub: no display available yet; deferring the overlay.")
            return
        }
        controller.show()
        notchController = controller
    }

    @objc private func screenParametersChanged() {
        installOverlayIfPossible()
        notchController?.repositionForActiveScreen()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(item.button)

        let menu = NSMenu()

        let header = NSMenuItem(title: "NotchHub", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "t")
        )
        menu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        )

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchHub", action: #selector(quit), keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func configureStatusButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        if let image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "NotchHub"
        ) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = "NH"
        }
        button.toolTip = "NotchHub"
        button.setAccessibilityLabel("NotchHub")
    }

    // MARK: - Actions

    @objc private func toggleNotch() {
        notchController?.toggle()
    }

    @objc private func openSettings() {
        notchController?.collapse()
        if settingsWindow == nil {
            let view = SettingsRootView(
                preferences: preferences,
                launchAtLogin: launchAtLogin,
                services: services
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "NotchHub Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 420)
            window.setContentSize(NSSize(width: 520, height: 640))
            window.setFrameAutosaveName("NotchHubSettings")
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
