import SwiftUI

/// The cache cleanup section of Settings.
///
/// Window surface, so system colours only — `NotchTheme` belongs to the
/// overlay. The footer is the long one on purpose: this is the only feature in
/// the app that moves a user's files, so the boundary of what it will and will
/// not touch has to be readable before the button is ever pressed.
struct CleanupSection: View {
    @Bindable var preferences: CleanupPreferences
    @ObservedObject var cleanup: CacheCleanupService
    let fullDiskAccessGranted: Bool

    var body: some View {
        Section {
            Toggle("Show cache cleanup in Focus", isOn: $preferences.showInFocus)
            if preferences.showInFocus {
                Toggle("Include developer caches", isOn: $preferences.includeDeveloperCaches)
                LabeledContent("Last scan", value: lastScan)
                LabeledContent("Last cleaned", value: lastClean)
                fullDiskAccessNote
                failureNote
            }
        } header: {
            Text("Cache cleanup")
        } footer: {
            Text(explanation)
        }
    }

    @ViewBuilder
    private var fullDiskAccessNote: some View {
        if !fullDiskAccessGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Caches inside sandboxed app containers are left out until Full Disk Access is granted.")
                    .foregroundStyle(.secondary)
                Button("Open Full Disk Access…") { SystemSettingsPane.fullDiskAccess.open() }
            }
        }
    }

    @ViewBuilder
    private var failureNote: some View {
        if case let .failed(error) = cleanup.state {
            Text(error.message).foregroundStyle(.red)
        }
    }

    private var lastScan: String {
        guard let summary = preferences.lastScan else { return "Not yet" }
        var parts = ["\(CleanupCopy.format(summary.safeBytes)) safe"]
        if summary.checkFirstCount > 0 {
            parts.append("\(summary.checkFirstCount) to check first")
        }
        parts.append(RelativeTime.ago(summary.date))
        return parts.joined(separator: " · ")
    }

    private var lastClean: String {
        guard let summary = preferences.lastClean else { return "Never" }
        let when = summary.date.formatted(date: .abbreviated, time: .omitted)
        return "\(CleanupCopy.format(summary.movedBytes)) moved to the Trash · \(when)"
    }

    private var explanation: String {
        "The Focus panel gains a second control: how much cache your apps can rebuild, and one click to move "
            + "the safe part of it to the Trash. Nothing is deleted outright, so anything can be put back.\n\n"
            + "NotchHub looks in ~/Library/Caches and ~/Library/Logs, in sandboxed app containers only when Full "
            + "Disk Access has already been granted, and in developer caches such as Xcode's derived data and the "
            + "npm and Homebrew caches only with the switch above. A folder it cannot identify is never offered. "
            + "Caches behind sign-in, iCloud, Spotlight, Mail, Photos, and sync apps are counted as check-first "
            + "and left where they are. Your Desktop, Documents, Downloads, and device backups are never read.\n\n"
            + "Under 64 MB counts as tidy. The number is refreshed when the panel opens and it is more than an "
            + "hour old, and the space itself is only free once you empty the Trash."
    }
}
