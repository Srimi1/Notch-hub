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
        } header: {
            Text("Popups")
        } footer: {
            Text("The popup only announces what was copied — hiding the Clipboard "
                + "module stops pasteboard reading entirely, popup or not.")
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
