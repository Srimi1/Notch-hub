import SwiftUI

/// The bounded, one-row versions of the Store-safe features. The full feature
/// views remain available for a future deliberate workspace tier.
public struct CompactSafeFeatureView: View {
    private let feature: SafeFeature
    private let workspace: SafeFeatureWorkspace

    public init(feature: SafeFeature, workspace: SafeFeatureWorkspace) {
        self.feature = feature
        self.workspace = workspace
    }

    public var body: some View {
        Group {
            switch feature {
            case .dashboard:
                CompactDashboardRow(model: workspace.dashboard)
            case .clipboard:
                CompactClipboardRow(model: workspace.clipboard)
            case .focus:
                CompactFocusRow(model: workspace.focus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: CompactNotchTheme.contentHeight)
    }
}

private struct CompactDashboardRow: View {
    let model: DashboardModel

    var body: some View {
        if let error = model.lastError {
            CompactIssueRow(message: error, actionTitle: "Retry", action: model.refresh)
        } else {
            HStack(spacing: 8) {
                CompactMetric(symbol: "clock.arrow.circlepath", value: uptime, label: "Uptime")
                CompactMetric(
                    symbol: "cpu",
                    value: model.snapshot.activeProcessorCount.formatted(),
                    label: "Cores"
                )
                CompactMetric(symbol: "memorychip", value: memory, label: "Memory")
                CompactMetric(
                    symbol: powerOrThermalSymbol,
                    value: powerOrThermalValue,
                    label: model.snapshot.isLowPowerModeEnabled ? "Power" : "Thermal"
                )
                CompactIconButton(symbol: "arrow.clockwise", help: "Refresh system status", action: model.refresh)
                    .disabled(model.isRefreshing)
            }
        }
    }

    private var uptime: String {
        let value = model.uptimeComponents
        if value.days > 0 { return "\(value.days)d \(value.hours)h" }
        if value.hours > 0 { return "\(value.hours)h \(value.minutes)m" }
        return "\(value.minutes)m"
    }

    private var memory: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: model.snapshot.physicalMemoryBytes),
            countStyle: .memory
        )
    }

    private var powerOrThermalSymbol: String {
        model.snapshot.isLowPowerModeEnabled ? "leaf.fill" : model.snapshot.thermalState.systemImage
    }

    private var powerOrThermalValue: String {
        model.snapshot.isLowPowerModeEnabled ? "Low power" : model.snapshot.thermalState.title
    }
}

private struct CompactMetric: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CompactNotchTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(
            CompactNotchTheme.subtleSurface,
            in: RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct CompactClipboardRow: View {
    let model: ClipboardHistoryModel

    var body: some View {
        if let issue = model.lastIssue {
            CompactIssueRow(message: issue.message, actionTitle: "Dismiss", action: model.dismissIssue)
        } else if !model.isEnabled {
            CompactMessageRow(
                symbol: "clipboard",
                title: "Clipboard history is off",
                message: "Nothing is read until you enable it.",
                actionTitle: "Enable",
                action: enable
            )
        } else if model.entries.isEmpty {
            CompactMessageRow(
                symbol: "clipboard",
                title: "No copied text yet",
                message: "New text stays in memory only.",
                actionTitle: "Turn off",
                action: model.disable
            )
        } else {
            entries
        }
    }

    private var entries: some View {
        ViewThatFits(in: .horizontal) {
            entryLayout(limit: 3)
            entryLayout(limit: 2)
            entryLayout(limit: 1)
        }
    }

    private func entryLayout(limit: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(model.entries.prefix(limit))) { entry in
                CompactClipboardEntry(entry: entry, model: model)
            }
            Spacer(minLength: 0)
            clipboardControls
        }
    }

    private var clipboardControls: some View {
        VStack(spacing: 4) {
            CompactTextButton(title: "Clear", action: model.clear)
            CompactTextButton(title: "Off", action: model.disable)
        }
    }

    private func enable() {
        Task { await model.enable() }
    }
}

private struct CompactClipboardEntry: View {
    let entry: ClipboardEntry
    let model: ClipboardHistoryModel

    var body: some View {
        Button {
            Task { _ = await model.restore(entry) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.copiedAt, style: .time)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(CompactNotchTheme.secondaryText)
            }
            .padding(7)
            .frame(width: 150, height: 54, alignment: .leading)
            .background(
                CompactNotchTheme.subtleSurface,
                in: RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius))
        }
        .buttonStyle(.plain)
        .help("Copy this item")
        .accessibilityLabel("Copy \(entry.preview)")
    }
}

private struct CompactFocusRow: View {
    let model: FocusTimerModel

    var body: some View {
        HStack(spacing: 12) {
            CompactFocusGauge(model: model)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.clockLabel)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach([15, 25, 50], id: \.self) { minutes in
                    CompactTextButton(
                        title: "\(minutes)m",
                        selected: model.selectedMinutes == minutes,
                        action: { _ = model.setDuration(minutes: minutes) }
                    )
                    .disabled(model.state == .running)
                }
            }
            CompactTextButton(title: primaryTitle, prominent: true, action: primaryAction)
            CompactIconButton(symbol: "arrow.counterclockwise", help: "Reset focus timer", action: model.reset)
                .disabled(model.state == .idle && model.progress == 0)
        }
    }

    private var statusText: String {
        model.lastIssue?.message ?? model.state.title
    }

    private var statusColor: Color {
        if model.lastIssue != nil { return .orange }
        switch model.state {
        case .running: return .cyan
        case .completed: return .green
        case .idle, .paused: return CompactNotchTheme.secondaryText
        }
    }

    private var primaryTitle: String {
        switch model.state {
        case .running: "Pause"
        case .paused: "Resume"
        case .completed: "Again"
        case .idle: "Start"
        }
    }

    private func primaryAction() {
        if model.state == .running {
            model.pause()
        } else {
            model.start()
        }
    }
}

private struct CompactFocusGauge: View {
    let model: FocusTimerModel

    var body: some View {
        ZStack {
            Circle().stroke(CompactNotchTheme.hoverSurface, lineWidth: 4)
            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: model.state == .completed ? "checkmark" : "timer")
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

private struct CompactIssueRow: View {
    let message: String
    let actionTitle: String
    let action: @MainActor () -> Void

    var body: some View {
        CompactMessageRow(
            symbol: "exclamationmark.triangle.fill",
            title: "Needs attention",
            message: message,
            actionTitle: actionTitle,
            action: action,
            tint: .orange
        )
    }
}

private struct CompactMessageRow: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: @MainActor () -> Void
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(CompactNotchTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(CompactNotchTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            CompactTextButton(title: actionTitle, action: action)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CompactTextButton: View {
    let title: String
    var selected = false
    var prominent = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        if prominent {
            return .white.opacity(0.9)
        }
        return selected ? CompactNotchTheme.selectedSurface : CompactNotchTheme.subtleSurface
    }
}

private struct CompactIconButton: View {
    let symbol: String
    let help: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(CompactNotchTheme.subtleSurface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
