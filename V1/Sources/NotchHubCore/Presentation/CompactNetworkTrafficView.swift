import NotchHubNetwork
import NotchHubSafeFeatures
import SwiftUI

struct CompactNetworkTrafficView: View {
    let model: NetworkTrafficModel
    let visibilityChanged: @MainActor (Bool, UUID) -> Void

    @State private var visibilityID = UUID()
    @AppStorage("networkTrafficUnit") private var storedUnit = NetworkTrafficUnit.megabitsPerSecond.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 20) {
                rate("Download", symbol: "arrow.down", mbps: model.snapshot.downloadMbps)
                rate("Upload", symbol: "arrow.up", mbps: model.snapshot.uploadMbps)
                Spacer(minLength: 0)
                unitPicker
            }
            HStack(spacing: 6) {
                Text(model.snapshot.interfaceName ?? "No interface")
                    .lineLimit(1)
                Text("·")
                Text(model.snapshot.state.message)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10))
            .foregroundStyle(CompactNotchTheme.secondaryText)
            .help("All apps on the selected interface, including local network traffic. "
                + "This is current traffic, not your connection's maximum speed.")
        }
        .frame(maxWidth: .infinity, maxHeight: 68, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network traffic across all apps, including local network traffic")
        .onAppear { visibilityChanged(true, visibilityID) }
        .onDisappear { visibilityChanged(false, visibilityID) }
    }

    private var unit: NetworkTrafficUnit {
        NetworkTrafficUnit(rawValue: storedUnit) ?? .megabitsPerSecond
    }

    private var unitPicker: some View {
        Picker("Speed unit", selection: Binding(get: { unit.rawValue }, set: { storedUnit = $0 })) {
            Text("Mbps").tag(NetworkTrafficUnit.megabitsPerSecond.rawValue)
            Text("MB/s").tag(NetworkTrafficUnit.megabytesPerSecond.rawValue)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Speed unit")
        .help("Choose megabits per second or megabytes per second")
    }

    private func rate(_ title: String, symbol: String, mbps: Double) -> some View {
        let reading = model.snapshot.state.hasReading ? unit.format(mbps: mbps) : nil
        return VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10))
                .foregroundStyle(CompactNotchTheme.secondaryText)
            Text(reading ?? "—")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reading.map { "\($0) \(unit.label)" } ?? "Unavailable")
    }
}
