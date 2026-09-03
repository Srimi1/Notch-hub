import SwiftUI

public struct DashboardFeatureView: View {
    private let model: DashboardModel

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error = model.lastError {
                SafeIssueBanner(message: error, actionTitle: "Retry", action: model.refresh)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                ForEach(metrics) { metric in
                    DashboardMetricTile(metric: metric)
                }
            }
            Spacer(minLength: 0)
            Label("Read locally with public macOS APIs", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { model.start() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System dashboard")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("System at a glance").font(.headline)
                Text(model.snapshot.sampledAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
            .help("Refresh system summary")
            .accessibilityLabel("Refresh system summary")
        }
    }

    private var metrics: [DashboardMetric] {
        let snapshot = model.snapshot
        return [
            DashboardMetric(
                id: "uptime",
                symbol: "clock.arrow.circlepath",
                title: uptimeLabel,
                subtitle: "Uptime"
            ),
            DashboardMetric(
                id: "processors",
                symbol: "cpu",
                title: snapshot.activeProcessorCount.formatted(),
                subtitle: "Active cores"
            ),
            DashboardMetric(
                id: "memory",
                symbol: "memorychip",
                title: memoryLabel,
                subtitle: "Physical memory"
            ),
            DashboardMetric(
                id: "thermal",
                symbol: snapshot.thermalState.systemImage,
                title: snapshot.thermalState.title,
                subtitle: "Thermal state"
            ),
            DashboardMetric(
                id: "power",
                symbol: snapshot.isLowPowerModeEnabled ? "leaf.fill" : "bolt.fill",
                title: snapshot.isLowPowerModeEnabled ? "Enabled" : "Normal",
                subtitle: "Low Power Mode"
            ),
        ]
    }

    private var uptimeLabel: String {
        let uptime = model.uptimeComponents
        if uptime.days > 0 {
            return "\(uptime.days)d \(uptime.hours)h"
        }
        if uptime.hours > 0 {
            return "\(uptime.hours)h \(uptime.minutes)m"
        }
        return "\(uptime.minutes)m"
    }

    private var memoryLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: model.snapshot.physicalMemoryBytes),
            countStyle: .memory
        )
    }
}

private struct DashboardMetric: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
}

private struct DashboardMetricTile: View {
    let metric: DashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: metric.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(metric.title)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(metric.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
