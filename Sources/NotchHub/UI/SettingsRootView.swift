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
    @Bindable var permissions: PermissionCenter
    @Bindable var hotKeys: HotKeyPreferences
    let services: ServiceHub
    /// Re-registers the chord with macOS after a change here.
    let onHotKeyChange: () -> Void

    var body: some View {
        Form {
            ModuleVisibilitySection(preferences: preferences)
            ShortcutSection(hotKeys: hotKeys, permissions: permissions, onChange: onHotKeyChange)
            PopupSection(preferences: services.hudPreferences)
            ScreenshotSection(
                preferences: services.screenshotPreferences,
                screenshots: services.screenshots
            )
            NextUpSettingsSections(
                preferences: services.activityPreferences,
                reminders: services.reminders,
                calendar: services.calendar
            )
            SystemAccessSection(permissions: permissions)
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

// MARK: - Screenshots

private struct ScreenshotSection: View {
    @Bindable var preferences: ScreenshotPreferences
    @Bindable var screenshots: ScreenshotService

    var body: some View {
        Section {
            Toggle("Copy screenshots to the clipboard", isOn: $preferences.autoCopy)
            if preferences.autoCopy {
                LabeledContent("Watching", value: screenshots.folderName)
                if screenshots.access == .unknown {
                    Button("Allow access to \(screenshots.folderName)…") {
                        screenshots.requestAccess()
                    }
                }
                Toggle("Move the file to the Trash after copying", isOn: $preferences.trashAfterCopying)
                previewDelayHint
                status
            }
        } header: {
            Text("Screenshots")
        } footer: {
            Text(explanation)
        }
    }

    /// Shown only while Screenshot.app's floating preview is on, because that
    /// is the only time the copy is slow. The toggle lives in that app's own
    /// Options menu, so this opens it rather than pretending to change it.
    @ViewBuilder
    private var previewDelayHint: some View {
        if ScreenshotPreviewHint.shouldExplainDelay(
            showsThumbnail: ScreenshotPreviewHint.showsThumbnail()
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("The copy waits for the floating preview to fade, which takes a few seconds.")
                    .foregroundStyle(NotchTheme.secondaryText)
                Button("Open Screenshot…") { ScreenshotPreviewHint.openScreenshotApp() }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let note = screenshots.statusNote {
            Text(note).foregroundStyle(NotchTheme.secondaryText)
        }
        if let failure = screenshots.lastError {
            Text(failure).foregroundStyle(.red)
            Button("Open Files and Folders…") { SystemSettingsPane.filesAndFolders.open() }
        }
    }

    private var explanation: String {
        "Every screenshot lands on the clipboard as well as in its folder, so you can paste it "
            + "straight away without holding Control while you shoot. Turning this on is what "
            + "asks macOS for access to that folder. NotchHub watches only that one folder, and "
            + "only opens a file macOS has already marked as a screenshot.\n\n"
            + "macOS writes the file when its floating preview fades, so the copy lands a few "
            + "seconds after the shutter. Nothing is deleted unless you switch that on, and it "
            + "goes to the Trash. Hiding the Clipboard module still leaves screenshots on the "
            + "clipboard — it only stops NotchHub keeping them in history or announcing them."
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
            Text("Hiding Clipboard, Calendar, Todo, or Media stops its local service. "
                + "Shared time, system, battery, Focus, and timer services remain active.")
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

// MARK: - Shortcut

/// The system-wide chord that opens the clipboard picker.
///
/// A fixed set of chords rather than a recorder: each is one macOS is unlikely
/// to have spoken for, and a recorder would let the user pick something already
/// taken and then wonder why nothing happens.
private struct ShortcutSection: View {
    @Bindable var hotKeys: HotKeyPreferences
    @Bindable var permissions: PermissionCenter
    let onChange: () -> Void

    /// The chord is a Carbon hot key and needs no permission; the double tap is
    /// a global key monitor and cannot see a keystroke without Accessibility.
    /// Switched on without it, the toggle simply does nothing, and a
    /// requirement buried in the footer is not where anyone looks when a
    /// gesture they just enabled fails to fire.
    @ViewBuilder
    private var doubleTapAccessNote: some View {
        if hotKeys.clipPickerDoubleTapN, !permissions.status(of: .accessibility).isGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("The double tap cannot see keystrokes until NotchHub has Accessibility. "
                    + "The shortcut above keeps working without it.")
                    .foregroundStyle(NotchTheme.secondaryText)
                Button("Allow Accessibility…") { permissions.request(.accessibility) }
            }
        }
    }

    var body: some View {
        Section {
            Toggle("Clipboard picker shortcut", isOn: $hotKeys.clipPickerEnabled)
                .onChange(of: hotKeys.clipPickerEnabled) { _, _ in onChange() }
            Picker("Shortcut", selection: $hotKeys.clipPickerSpecID) {
                ForEach(HotKeyCenter.presets) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .onChange(of: hotKeys.clipPickerSpecID) { _, _ in onChange() }
            .disabled(!hotKeys.clipPickerEnabled)
            Toggle("Also open by tapping N twice", isOn: $hotKeys.clipPickerDoubleTapN)
                .onChange(of: hotKeys.clipPickerDoubleTapN) { _, _ in onChange() }
            doubleTapAccessNote
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Press it from any app to drop your clipboard history out of the notch, "
                + "then press 1–9 to paste one. ⌘Space is not offered — Spotlight owns it "
                + "at a level no app can take.\n\n"
                + "The double tap needs Accessibility, and only fires after a pause in "
                + "typing — words like \"announce\" will not set it off. It does not take "
                + "the key away from anything, so the two letters are still typed.")
        }
    }
}

// MARK: - Popups

private struct PopupSection: View {
    @Bindable var preferences: HudPreferences

    var body: some View {
        Section {
            Toggle("Show a popup when you copy", isOn: $preferences.copyPopup)
            Toggle("Show a popup when power connects", isOn: $preferences.chargingPopup)
            Toggle("Paste automatically when you pick a clip", isOn: $preferences.autoPaste)
        } header: {
            Text("Popups")
        } footer: {
            Text("The popup only announces what was copied — hiding the Clipboard "
                + "module stops pasteboard reading entirely, popup or not. Automatic "
                + "pasting types the ⌘V for you and needs Accessibility; without it "
                + "the clip is still copied.")
        }
    }
}

// MARK: - System access

/// Every permission NotchHub uses, what it buys, and the one control that moves
/// it forward. Some of these can be prompted for; Full Disk Access can only be
/// granted by hand, so its row opens the pane instead.
private struct SystemAccessSection: View {
    @Bindable var permissions: PermissionCenter

    var body: some View {
        Section {
            ForEach(PermissionCenter.Permission.allCases) { permission in
                PermissionRowView(
                    permission: permission,
                    status: permissions.status(of: permission)
                ) {
                    permissions.request(permission)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("macOS grants these, not NotchHub — Accessibility, Automation, and Full Disk "
                + "Access are switches only you can flip. Anything not granted simply stays "
                + "quiet; nothing else breaks.")
        }
        .task { await permissions.refreshAll() }
        // The switches live in another app, so re-read whenever this one returns.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await permissions.refreshAll() }
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
