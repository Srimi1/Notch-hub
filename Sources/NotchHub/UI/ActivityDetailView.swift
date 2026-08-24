import SwiftUI

struct ActivityDetailView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Bindable var coordinator: ActivityCoordinator

    var body: some View {
        HStack(spacing: 14) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
            Divider().overlay(NotchTheme.divider)
            queue
                .frame(maxWidth: 220)
            Button("Dashboard") { viewModel.dismissActivity() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.secondaryText)
                .help("Show the module dashboard")
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var summary: some View {
        if let activity = viewModel.presentedActivity {
            HStack(spacing: 10) {
                icon(for: activity, size: 19, glyphHeight: 15)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(viewModel.actionError ?? activity.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.actionError == nil ? NotchTheme.secondaryText : .red)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let activity = viewModel.presentedActivity {
            HStack(spacing: 7) {
                ForEach(Array(activity.actions.enumerated()), id: \.offset) { _, action in
                    Button { viewModel.perform(action) } label: {
                        Label(action.title, systemImage: action.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .notchPrimaryAction(action == activity.actions.first)
                }
            }
        }
    }

    /// Battery shows the live glyph so its colour tracks the real state — the
    /// static `ActivityKind.tint` is always yellow, which would contradict the
    /// red the notch shows for the very same battery elsewhere.
    @ViewBuilder
    private func icon(for activity: ActivitySnapshot, size: CGFloat, glyphHeight: CGFloat) -> some View {
        if activity.kind == .battery {
            let battery = viewModel.services.battery
            BatteryGlyphView(
                level: battery.level,
                state: BatteryGlyphState.resolve(
                    percent: battery.percent,
                    isCharging: battery.isCharging,
                    isCharged: battery.isCharged,
                    isLowPowerMode: battery.isLowPowerMode,
                    warningPercent: viewModel.services.activityPreferences.batteryWarningPercent
                ),
                height: glyphHeight
            )
        } else {
            Image(systemName: activity.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(activity.kind.tint)
        }
    }

    private var queue: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(coordinator.queue) { activity in
                    Button { viewModel.present(activity) } label: {
                        icon(for: activity, size: 11, glyphHeight: 10)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(
                                    activity.id == viewModel.presentedActivity?.id
                                        ? Color.white.opacity(0.2)
                                        : Color.white.opacity(0.07)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(activity.kind.title): \(activity.title)")
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func notchPrimaryAction(_ isPrimary: Bool) -> some View {
        if isPrimary {
            keyboardShortcut(.defaultAction)
        } else {
            self
        }
    }
}
