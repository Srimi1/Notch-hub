import NotchHubNetwork
import SwiftUI

/// A glance at traffic on the active interface, sampled only while displayed.
@MainActor
struct NetworkModuleView: View {
    let model: NetworkTrafficModel
    @Bindable var preferences: NetworkModulePreferences
    var onPresentationChange: (UUID, Bool) -> Void
    @State private var presentationID = UUID()

    var body: some View {
        HStack(spacing: 8) {
            rate(symbol: "arrow.down", title: "Download", mbps: model.snapshot.downloadMbps)
            rate(symbol: "arrow.up", title: "Upload", mbps: model.snapshot.uploadMbps)
            VStack(alignment: .leading, spacing: 3) {
                Text(interfaceLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(2)
                unitPicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: NotchTheme.contentHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current network traffic across all apps")
        .onAppear { onPresentationChange(presentationID, true) }
        .onDisappear { onPresentationChange(presentationID, false) }
    }

    private func rate(symbol: String, title: String, mbps: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.secondaryText)
            Text(rateValue(mbps))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Current traffic · all apps")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 8)
        .background(NotchTheme.subtleSurface, in: RoundedRectangle(cornerRadius: NotchTheme.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var unitPicker: some View {
        Picker("Traffic units", selection: $preferences.unit) {
            Text("Mbps").tag(NetworkTrafficUnit.megabitsPerSecond)
            Text("MB/s").tag(NetworkTrafficUnit.megabytesPerSecond)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.mini)
        .fixedSize()
        .help("Display megabits or megabytes per second")
        .accessibilityLabel("Traffic units")
    }

    private func rateValue(_ mbps: Double) -> String {
        guard model.snapshot.state.hasReading else { return "—" }
        return "\(preferences.unit.format(mbps: mbps)) \(preferences.unit.label)"
    }

    private var interfaceLabel: String {
        model.snapshot.interfaceName ?? "Active interface"
    }

    private var statusLabel: String {
        model.snapshot.state.hasReading ? "Local traffic is included" : model.snapshot.state.message
    }
}
