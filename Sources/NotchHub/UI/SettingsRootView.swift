import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case nextUp
    case aiCredits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextUp: "Next Up"
        case .aiCredits: "AI Credits"
        }
    }

    var symbol: String {
        switch self {
        case .nextUp: "waveform.path.ecg"
        case .aiCredits: "key.fill"
        }
    }
}

struct SettingsRootView: View {
    let services: ServiceHub

    @State private var selection: SettingsSection? = .nextUp

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("NotchHub")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail
                .navigationTitle(activeSection.title)
        }
        .frame(minWidth: 620, minHeight: 540)
    }

    @ViewBuilder
    private var detail: some View {
        switch activeSection {
        case .nextUp:
            ActivitySettingsView(
                preferences: services.activityPreferences,
                reminders: services.reminders
            )
        case .aiCredits:
            CreditSettingsView(prefs: services.creditPrefs, credit: services.credit)
        }
    }

    private var activeSection: SettingsSection {
        selection ?? .nextUp
    }
}
