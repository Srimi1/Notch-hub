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
            } else if viewModel.showCollapsedWings {
                CollapsedStripView(
                    time: viewModel.services.time,
                    coordinator: viewModel.services.activityCoordinator,
                    wingWidth: viewModel.collapsedWingWidth
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
    let wingWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ClockWingView(time: time)
                .frame(width: wingWidth, alignment: .leading)
            Spacer(minLength: 0) // central camera housing — kept clear
            ActivityWingView(activity: coordinator.currentActivity)
                .frame(width: wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
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
    let activity: ActivitySnapshot?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: activity?.symbol ?? "circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(activity?.kind.tint ?? .white)
            Text(wingText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var wingText: String {
        activity?.compactLabel ?? ""
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
