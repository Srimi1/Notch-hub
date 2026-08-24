import AppKit
import ServiceManagement
import SwiftUI

/// Owns the app lifecycle: spins up the notch overlay window and a menu-bar
/// status item, and re-positions the overlay when the display configuration
/// changes (external monitor connected, resolution change, sleep/wake).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let instanceCoordinator = AppInstanceCoordinator()
    private let preferences = ModulePreferences()

    /// Modules offered as visibility toggles in the status menu — the ones backed
    /// by real implementations today (the rest render placeholders, so toggling
    /// them isn't meaningful yet).
    private let toggleableModules = ModulePreferences.defaultVisibleModules

    private static let loginItemTag = 100

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceCoordinator.shouldContinueLaunching() else {
            NSApplication.shared.terminate(nil)
            return
        }

        // Clear API keys left by the removed credit tracker. No-op after the
        // first run; see `LegacyCredentialCleanup`.
        LegacyCredentialCleanup.runIfNeeded()

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
        guard let controller = NotchWindowController(preferences: preferences) else {
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
        menu.delegate = self

        let header = NSMenuItem(title: "NotchHub", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "t")
        )
        menu.addItem(makeModulesItem())
        menu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        )

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        loginItem.tag = Self.loginItemTag
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchHub", action: #selector(quit), keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    /// A "Modules" submenu with a visibility checkbox per implemented module.
    private func makeModulesItem() -> NSMenuItem {
        let modulesItem = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu()
        for module in toggleableModules {
            let entry = NSMenuItem(
                title: module.title,
                action: #selector(toggleModule(_:)),
                keyEquivalent: ""
            )
            entry.representedObject = module.rawValue
            entry.target = self
            modulesMenu.addItem(entry)
        }
        modulesItem.submenu = modulesMenu
        return modulesItem
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

    // MARK: - NSMenuDelegate

    /// Refresh checkbox states each time the menu opens, so they reflect the
    /// current preferences and the live launch-at-login registration status.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == Self.loginItemTag {
                item.state = launchAtLoginEnabled ? .on : .off
            }
            guard let submenu = item.submenu else { continue }
            for entry in submenu.items {
                guard let raw = entry.representedObject as? String,
                      let module = FeatureModule(rawValue: raw) else { continue }
                entry.state = preferences.isVisible(module) ? .on : .off
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleNotch() {
        notchController?.toggle()
    }

    @objc private func openSettings() {
        guard let services = notchController?.services else { return }
        notchController?.collapse()
        if settingsWindow == nil {
            let view = SettingsRootView(services: services)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "NotchHub Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 560)
            window.setContentSize(NSSize(width: 680, height: 680))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let module = FeatureModule(rawValue: raw) else { return }
        preferences.setModule(module, visible: !preferences.isVisible(module))
        sender.state = preferences.isVisible(module) ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("NotchHub: launch-at-login toggle failed: \(error.localizedDescription)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
