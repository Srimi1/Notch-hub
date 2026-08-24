import SwiftUI

/// The whole settings surface, on one screen.
///
/// This was a `NavigationSplitView` whose sidebar held a single row — navigation
/// for a choice that didn't exist. NotchHub has about one screen's worth of
/// settings, so it gets one screen, and the module switches move here from the
/// menu bar where they had no room to explain themselves.
struct SettingsRootView: View {

    @ObservedObject var preferences: ModulePreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    let services: ServiceHub

    var body: some View {
        Form {
            ModuleVisibilitySection(preferences: preferences)
            PopupSection(preferences: services.hudPreferences)
            NextUpSettingsSections(
                preferences: services.activityPreferences,
                reminders: services.reminders,
                calendar: services.calendar
            )
            SystemAccessSection()
            GeneralSection(launchAtLogin: launchAtLogin)
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The login-item switch can also be flipped in System Settings, and
        // macOS posts no notification when it is.
        .onAppear { launchAtLogin.refresh() }
    }
}

// MARK: - Modules

private struct ModuleVisibilitySection: View {
    @ObservedObject var preferences: ModulePreferences

    var body: some View {
        Section {
            ForEach(FeatureModule.allCases) { module in
                Toggle(isOn: binding(for: module)) {
                    Label(module.title, systemImage: module.symbol)
                }
            }
        } header: {
            Text("Modules")
        } footer: {
            Text("Hiding a module removes it from the notch and stops the service behind it — "
                + "clipboard reads, calendar access, and Apple Events to your music player "
                + "stop with it.")
        }
    }

    /// Routed through `isVisible`/`setModule` rather than binding the array
    /// directly: `setModule` re-sorts into canonical enum order, which is what
    /// keeps the notch chip band stable no matter what order things are toggled.
    private func binding(for module: FeatureModule) -> Binding<Bool> {
        Binding(
            get: { preferences.isVisible(module) },
            set: { preferences.setModule(module, visible: $0) }
        )
    }
}

// MARK: - Popups

private struct PopupSection: View {
    @Bindable var preferences: HudPreferences

    var body: some View {
        Section {
            Toggle("Show a popup when you copy", isOn: $preferences.copyPopup)
            Toggle("Show a popup when power connects", isOn: $preferences.chargingPopup)
        } header: {
            Text("Popups")
        } footer: {
            Text("The popup only announces what was copied — hiding the Clipboard "
                + "module stops pasteboard reading entirely, popup or not.")
        }
    }
}

// MARK: - System access

/// Full Disk Access cannot be requested, only granted by hand — so the app's
/// job is to say plainly whether it has it and open the right pane.
private struct SystemAccessSection: View {
    @State private var granted = FullDiskAccess.isGranted()
    @State private var openFailed = false

    private var statusTitle: String { granted ? "Granted" : "Not granted" }
    private var statusSymbol: String {
        granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var footerText: String {
        if granted {
            return "NotchHub can read files you copy without macOS asking folder by folder."
        }
        return "Without it, macOS asks separately for Desktop, Documents, Downloads, and "
            + "iCloud Drive the first time you copy a file out of each one. Granting Full "
            + "Disk Access answers all of them at once. Drag NotchHub into the list, or tick "
            + "it if it is already there, then reopen this window."
    }

    var body: some View {
        Section {
            HStack {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(granted ? Color.secondary : Color.orange)
                Spacer()
                Button(granted ? "Open Settings" : "Grant Access…") {
                    openFailed = !FullDiskAccess.openSettingsPane()
                }
            }
            if openFailed {
                Text("System Settings could not be opened. Grant it under "
                    + "Privacy & Security ▸ Full Disk Access.")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Full Disk Access")
        } footer: {
            Text(footerText)
        }
        // The switch lives in another app, so re-read whenever this one returns.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            granted = FullDiskAccess.isGranted()
        }
    }
}

// MARK: - General

private struct GeneralSection: View {
    @Bindable var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Section("General") {
            Toggle("Launch NotchHub at login", isOn: $launchAtLogin.isEnabled)
            if let note = launchAtLogin.statusMessage {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let failure = launchAtLogin.lastError {
                Text(failure).foregroundStyle(.red)
            }
        }
    }
}
