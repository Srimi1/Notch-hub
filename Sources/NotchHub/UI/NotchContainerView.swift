import SwiftUI

/// Root overlay view. The black pill itself is drawn by `HoverView`'s layer
/// mask (sized by the window controller); this view fills it with content:
/// the collapsed live strip when idle, the full dashboard when expanded.
struct NotchContainerView: View {

    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ZStack {
            if viewModel.isExpanded {
                ExpandedDashboardView(viewModel: viewModel)
                    .padding(.horizontal, NotchTheme.horizontalPadding)
                    .padding(.vertical, NotchTheme.verticalPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if viewModel.hudContent != nil {
                NotchHUDView(
                    viewModel: viewModel,
                    clipboard: viewModel.services.clipboard,
                    battery: viewModel.services.battery
                )
                .transition(.opacity)
            } else if viewModel.showCollapsedWings {
                CollapsedStripView(
                    time: viewModel.services.time,
                    coordinator: viewModel.services.activityCoordinator,
                    battery: viewModel.services.battery,
                    media: viewModel.services.media,
                    warningPercent: viewModel.services.activityPreferences.batteryWarningPercent,
                    wingWidth: viewModel.collapsedWingWidth,
                    wingPadding: viewModel.collapsedWingPadding
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// The collapsed Live-Activities strip: a wing on each side of the central
/// camera gap. Left wing = clock; right wing = the single most relevant live
/// activity (now playing › focus › low battery).
private struct CollapsedStripView: View {

    @ObservedObject var time: TimeService
    @Bindable var coordinator: ActivityCoordinator
    @ObservedObject var battery: BatteryService
    @ObservedObject var media: MediaService
    let warningPercent: Int
    let wingWidth: CGFloat
    let wingPadding: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ClockWingView(time: time)
                .frame(width: wingWidth, alignment: .leading)
            Spacer(minLength: 0) // central camera housing — kept clear
            ActivityWingView(
                activity: coordinator.currentActivity,
                battery: battery,
                media: media,
                warningPercent: warningPercent
            )
            .frame(width: wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, wingPadding)
        .foregroundStyle(.white)
    }
}

private struct ClockWingView: View {
    @ObservedObject var time: TimeService
    var body: some View {
        HStack(spacing: 4) {
            Text(time.clock)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(time.meridiem)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .offset(y: -1)
        }
    }
}

private struct ActivityWingView: View {
    /// The pill is only 32pt tall on a display with no notch, so this is the
    /// safe ceiling rather than a taste call. It leaves the title around 85 of
    /// the wing's 112 points, which still truncates tidily.
    static let astronautSide: CGFloat = 22

    let activity: ActivitySnapshot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var battery: BatteryService
    @ObservedObject var media: MediaService
    let warningPercent: Int

    /// Nothing to say means nothing to draw. The strip appears on a published
    /// flag while the activity itself arrives on its own schedule, so the two
    /// can disagree for a moment — and a placeholder dot beside an empty label
    /// is worse than an empty wing. The parent still reserves the slot, so the
    /// notch body does not shift when the activity lands.
    var body: some View {
        if let activity {
            HStack(spacing: 5) {
                leading
                Text(activity.compactLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
            }
        }
    }

    /// Battery is the one activity whose icon carries live state worth drawing —
    /// charge level, and the colour that says whether to act. Every other kind
    /// is a fixed symbol, so it keeps the cheaper path.
    @ViewBuilder
    private var leading: some View {
        if activity?.kind == .battery {
            BatteryGlyphView(level: battery.level, state: batteryState, height: 11)
        } else if activity?.kind == .media {
            // The astronaut listens along here rather than only inside the
            // dashboard's Media panel, which is the one place it used to live
            // and the one place nobody is looking while they are just playing
            // music. It brings its own motion, so the breathing scale the
            // symbol used to do would only fight it.
            //
            // Play state comes from the service, not from `activity.symbol`:
            // the snapshot carries no such flag and encodes it in the symbol
            // name, which is a display detail and a poor thing to branch on.
            MediaAstronautView(
                isPlaying: media.isPlaying,
                ink: .white,
                cropsToFigure: true,
                fallbackSymbol: activity?.symbol ?? "waveform"
            )
            .frame(width: Self.astronautSide, height: Self.astronautSide)
        } else {
            Image(systemName: activity?.symbol ?? "circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(activity?.kind.tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var batteryState: BatteryGlyphState {
        BatteryGlyphState.resolve(
            percent: battery.percent,
            isCharging: battery.isCharging,
            isCharged: battery.isCharged,
            isLowPowerMode: battery.isLowPowerMode,
            warningPercent: warningPercent
        )
    }
}

extension ActivityKind {
    var tint: Color {
        switch self {
        case .calendar: .blue
        case .timer: .orange
        case .reminder: .green
        case .battery: .yellow
        case .media: .mint
        case .focus: .purple
        }
    }
}
