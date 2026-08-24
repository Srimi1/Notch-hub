import AppKit
import SwiftUI

/// The Next Up half of the settings window. Vends sections rather than its own
/// `Form`, so it composes into the single settings surface.
struct NextUpSettingsSections: View {
    @Bindable var preferences: ActivityPreferences
    @Bindable var reminders: ReminderService
    /// Combine-based, unlike the `@Observable` types above.
    @ObservedObject var calendar: CalendarService
    @State private var settingsError: String?

    var body: some View {
        Group {
            Section("Activity Types") {
                ForEach(ActivityKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: binding(for: kind))
                }
            }
            timingSection
            Section("Behavior") {
                Toggle("Urgent activities override media", isOn: $preferences.urgentOverridesMedia)
            }
            remindersSection
            calendarSection
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            Stepper(
                "Calendar lead time: \(preferences.calendarLeadMinutes) min",
                value: $preferences.calendarLeadMinutes,
                in: 5 ... 60,
                step: 5
            )
            Stepper(
                "Reminder lead time: \(preferences.reminderLeadMinutes) min",
                value: $preferences.reminderLeadMinutes,
                in: 5 ... 240,
                step: 5
            )
            Stepper(
                "Battery warning: \(preferences.batteryWarningPercent)%",
                value: $preferences.batteryWarningPercent,
                in: 5 ... 50,
                step: 5
            )
        }
    }

    private var remindersSection: some View {
        Section("Reminders Access") {
            HStack {
                Text(reminderStatus)
                    .foregroundStyle(reminders.access == .denied ? .red : .secondary)
                Spacer()
                if reminders.access == .unknown {
                    Button("Request Access") {
                        Task { @MainActor in await reminders.requestAccess() }
                    }
                } else if reminders.access == .denied {
                    Button("Open System Settings") { openSystemSettings() }
                }
            }
            if let settingsError {
                Text(settingsError).foregroundStyle(.red)
            }
        }
    }

    /// Calendar access is never requested automatically, so the only way to
    /// grant it from a keyboard-reachable surface is this button.
    private var calendarSection: some View {
        Section("Calendar Access") {
            HStack {
                Text(calendarStatus)
                    .foregroundStyle(calendar.access == .denied ? .red : .secondary)
                Spacer()
                switch calendar.access {
                case .unknown:
                    Button("Request Access") { calendar.requestAccess() }
                case .denied:
                    Button("Open System Settings") { openSystemSettings() }
                case .granted:
                    EmptyView()
                }
            }
        }
    }

    private var calendarStatus: String {
        switch calendar.access {
        case .unknown: "Not requested"
        case .granted: "Granted"
        case .denied: calendar.lastError ?? "Denied in System Settings"
        }
    }

    private func binding(for kind: ActivityKind) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(kind) },
            set: { preferences.setEnabled(kind, enabled: $0) }
        )
    }

    private var reminderStatus: String {
        switch reminders.access {
        case .unknown: "Not requested"
        case .granted: "Granted"
        case .denied: reminders.lastError ?? "Denied in System Settings"
        }
    }

    private func openSystemSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            settingsError = "System Settings is unavailable."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in settingsError = error.localizedDescription }
        }
    }
}
