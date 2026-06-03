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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if viewModel.showCollapsedWings {
                CollapsedStripView(
                    services: viewModel.services,
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

    @ObservedObject var services: ServiceHub
    let wingWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ClockWingView(time: services.time)
                .frame(width: wingWidth, alignment: .leading)
            Spacer(minLength: 0) // central camera housing — kept clear
            rightWing
                .frame(width: wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var rightWing: some View {
        if services.media.nowPlaying != nil {
            MediaWingView(media: services.media)
        } else if services.focus.isOn {
            FocusWingView()
        } else {
            BatteryWingView(battery: services.battery)
        }
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

private struct MediaWingView: View {
    @ObservedObject var media: MediaService
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: media.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
            Text(media.nowPlaying?.title ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct FocusWingView: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.purple)
            Text("Focus")
                .font(.system(size: 11, weight: .semibold))
        }
    }
}

private struct BatteryWingView: View {
    @ObservedObject var battery: BatteryService
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: battery.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(battery.percent <= 20 ? .red : .white)
            Text("\(battery.percent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
