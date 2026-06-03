import AppKit
import ServiceManagement

/// Owns the app lifecycle: spins up the notch overlay window and a menu-bar
/// status item, and re-positions the overlay when the display configuration
/// changes (external monitor connected, resolution change, sleep/wake).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private let preferences = ModulePreferences()

    /// Modules offered as visibility toggles in the status menu — the ones backed
    /// by real implementations today (the rest render placeholders, so toggling
    /// them isn't meaningful yet).
    private let toggleableModules = ModulePreferences.defaultVisibleModules

    private static let loginItemTag = 100

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        let controller = NotchWindowController(preferences: preferences)
        controller.show()
        notchController = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        notchController?.repositionForActiveScreen()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◖◗"

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
                title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: ""
            )
            entry.representedObject = module.rawValue
            entry.target = self
            modulesMenu.addItem(entry)
        }
        modulesItem.submenu = modulesMenu
        return modulesItem
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
