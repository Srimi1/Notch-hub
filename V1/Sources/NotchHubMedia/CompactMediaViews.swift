import Lottie
import NotchHubSafeFeatures
import SwiftUI

/// The bounded v0.6 media row, kept inside V1's 68-point content ribbon.
public struct CompactMediaBarView: View {
    private let model: MediaPresentationModel
    @State private var presentedControlIssue: String?

    public init(model: MediaPresentationModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            MediaAstronautView(
                isPlaying: model.isPlaying,
                fallbackSymbol: nil,
                fallbackColor: .black.opacity(0.78)
            )
            .frame(width: MediaAstronautView.panelSide, height: MediaAstronautView.panelSide)
            mediaDetails
        }
        .foregroundStyle(.white)
        .frame(
            maxWidth: .infinity,
            minHeight: CompactNotchTheme.contentHeight,
            maxHeight: CompactNotchTheme.contentHeight,
            alignment: .leading
        )
        .clipped()
        .onChange(of: model.lastControlIssue, initial: true) { _, issue in
            presentedControlIssue = issue
        }
        .alert("Playback Control Failed", isPresented: presentsControlIssue) {
            Button("OK", role: .cancel) { presentedControlIssue = nil }
        } message: {
            Text(presentedControlIssue ?? "Playback control is unavailable.")
        }
    }

    @ViewBuilder
    private var mediaDetails: some View {
        if let nowPlaying = model.nowPlaying {
            nowPlayingDetails(nowPlaying)
        } else if let reason = model.unavailableReason {
            CompactMediaHint(symbol: "hand.raised.fill", text: reason)
        } else {
            CompactMediaHint(symbol: "play.slash", text: model.emptyHint)
        }
    }

    private func nowPlayingDetails(_ nowPlaying: MediaNowPlaying) -> some View {
        HStack(spacing: 12) {
            CompactMediaMetadata(nowPlaying: nowPlaying)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                MediaTransportButton(model: model, command: .previous, symbol: "backward.fill", label: "Previous")
                MediaTransportButton(
                    model: model,
                    command: .playPause,
                    symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    label: nowPlaying.isPlaying ? "Pause" : "Play"
                )
                MediaTransportButton(model: model, command: .next, symbol: "forward.fill", label: "Next")
            }
        }
    }

    private var presentsControlIssue: Binding<Bool> {
        Binding(
            get: { presentedControlIssue != nil },
            set: { if !$0 { presentedControlIssue = nil } }
        )
    }
}

/// The right-hand collapsed activity used when a current track exists.
public struct CompactMediaWingView: View {
    private let model: MediaPresentationModel

    public init(model: MediaPresentationModel) {
        self.model = model
    }

    public var body: some View {
        if let nowPlaying = model.nowPlaying {
            HStack(spacing: 5) {
                MediaAstronautView(
                    isPlaying: nowPlaying.isPlaying,
                    ink: .white,
                    cropsToFigure: true,
                    fallbackSymbol: nowPlaying.isPlaying ? "waveform" : "pause.fill",
                    fallbackColor: .mint
                )
                .frame(width: MediaAstronautView.wingSide, height: MediaAstronautView.wingSide)
                Text(nowPlaying.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: nowPlaying))
        }
    }

    private func accessibilityLabel(for nowPlaying: MediaNowPlaying) -> String {
        "\(nowPlaying.isPlaying ? "Playing" : "Paused"): \(nowPlaying.title)"
    }
}

private struct CompactMediaMetadata: View {
    let nowPlaying: MediaNowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nowPlaying.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(nowPlaying.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

private struct CompactMediaHint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MediaTransportButton: View {
    let model: MediaPresentationModel
    let command: MediaTransportCommand
    let symbol: String
    let label: String

    var body: some View {
        Button {
            model.send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(MediaTransportButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct MediaTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MediaTransportButtonSurface(configuration: configuration)
    }
}

private struct MediaTransportButtonSurface: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(Circle().fill(surface))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction)
            .onHover { isHovered = $0 }
    }

    private var interaction: MediaControlInteraction {
        guard isEnabled else { return .resting }
        if configuration.isPressed {
            return .pressed
        }
        return isHovered ? .hovered : .resting
    }

    private var surface: Color {
        switch interaction {
        case .resting: CompactNotchTheme.subtleSurface
        case .hovered: CompactNotchTheme.hoverSurface
        case .pressed: CompactNotchTheme.pressedSurface
        }
    }
}

private enum MediaControlInteraction: Equatable {
    case resting
    case hovered
    case pressed
}

/// The same authored astronaut is shared by the full media row and collapsed wing.
struct MediaAstronautView: View {
    static let panelSide: CGFloat = 56
    static let wingSide: CGFloat = 22
    static let figureFraction: CGFloat = 0.46
    static let tile = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xF9 / 255)

    let isPlaying: Bool
    var ink: AstronautAnimation.Ink = .asDrawn
    var cropsToFigure = false
    var fallbackSymbol: String?
    var fallbackColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: LottieAnimation?

    var body: some View {
        Group {
            if cropsToFigure {
                croppedArtwork
            } else {
                panelArtwork
            }
        }
        .task(id: ink) { await loadAnimation() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var panelArtwork: some View {
        if let animation {
            player(animation)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius).fill(Self.tile)
                )
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var croppedArtwork: some View {
        if let animation {
            figure(animation)
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let fallbackSymbol {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(fallbackColor)
        } else {
            Color.clear
        }
    }

    private func loadAnimation() async {
        animation = nil
        let loaded = await AstronautAnimation.load(ink)
        guard !Task.isCancelled else { return }
        animation = loaded
    }

    private func figure(_ animation: LottieAnimation) -> some View {
        GeometryReader { proxy in
            let slot = min(proxy.size.width, proxy.size.height)
            let artworkSide = slot / Self.figureFraction
            player(animation)
                .frame(width: artworkSide, height: artworkSide)
                .offset(x: -(artworkSide - slot) / 2, y: -(artworkSide - slot) / 2)
        }
        .clipped()
    }

    private func player(_ animation: LottieAnimation) -> some View {
        LottieView(animation: animation)
            .resizable()
            .backgroundBehavior(.pauseAndRestore)
            .playbackMode(AstronautMotion(isPlaying: isPlaying, reduceMotion: reduceMotion).lottieMode)
    }
}
