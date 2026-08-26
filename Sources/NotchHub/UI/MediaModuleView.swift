import Lottie
import SwiftUI

/// The Media panel: an astronaut with headphones, and whatever is playing.
///
/// Split out of `ExpandedDashboardView` for the same reason `DashboardModuleView`
/// was — that file was twenty lines under the 500-line lint cap and this view
/// grew.
struct MediaModuleView: View {
    @ObservedObject var media: MediaService

    var body: some View {
        HStack(spacing: 12) {
            MediaAstronautView(isPlaying: media.nowPlaying?.isPlaying ?? false)
                .frame(width: MediaAstronautView.side, height: MediaAstronautView.side)
            details
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var details: some View {
        if let np = media.nowPlaying {
            nowPlaying(np)
        } else if let reason = media.unavailableReason {
            // Denied Automation is not the same as an idle player. Saying
            // "play something" while music is audibly playing is a lie the
            // user has no way to diagnose — macOS never re-prompts.
            EmptyHint(symbol: "hand.raised.fill", text: reason)
        } else {
            EmptyHint(symbol: "play.slash", text: media.emptyHint)
        }
    }

    private func nowPlaying(_ np: NowPlaying) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(np.artist.isEmpty ? np.app.name : np.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                TransportButton(symbol: "backward.fill") { media.previous() }
                TransportButton(symbol: np.isPlaying ? "pause.fill" : "play.fill") { media.playPause() }
                TransportButton(symbol: "forward.fill") { media.next() }
            }
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(NotchButtonStyle(shape: .circle))
    }
}

// MARK: - The astronaut

/// "Astronaut and music" by Artemiy, played as authored.
///
/// The file is a plain Bodymovin JSON bundled beside the app; when it is not
/// there — a `swift run`, a bundle assembled by other means — this draws
/// nothing at all and the panel reads exactly as it did before. Decoration is
/// never worth an error message.
struct MediaAstronautView: View {
    /// The artwork is square at 1000×1000, so one number is the whole frame.
    /// The module row is a hard 68pt with `.clipped()`, which leaves this about
    /// six points of air top and bottom.
    static let side: CGFloat = 56

    /// What the astronaut sits on.
    ///
    /// The artwork is drawn for a light ground: the figure, the stars and the
    /// notes are one near-black, and the only white in the file is the
    /// highlight cut into the helmet and the visor. Against the panel's black
    /// that near-black contrasts 1.12:1, so the stars and notes were simply
    /// absent and the astronaut read as a dim smudge. On the ground it was
    /// drawn for, every mark lands and the highlights read as the cutouts they
    /// are.
    static let tile = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xF9 / 255)

    /// Whether the music is actually playing. The astronaut listens along, so
    /// it moves while the track does and settles when the track is paused.
    var isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: LottieAnimation?

    var body: some View {
        Group {
            if let animation {
                player(animation)
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(Self.tile)
                    )
            } else {
                Color.clear
            }
        }
        .task { animation = await AstronautAnimation.load() }
        .accessibilityHidden(true)
    }

    /// Held still when the music is paused, and under Reduce Motion, which is
    /// the same bargain every other animation in the notch strikes. Pausing on
    /// the current frame rather than rewinding means a track paused and resumed
    /// picks the astronaut up where it left off.
    private func player(_ animation: LottieAnimation) -> some View {
        LottieView(animation: animation)
            .resizable()
            .backgroundBehavior(.pauseAndRestore)
            .playbackMode(
                AstronautMotion(isPlaying: isPlaying, reduceMotion: reduceMotion).lottieMode
            )
    }
}

/// Whether the astronaut is moving, kept as NotchHub's own type so the rule can
/// be tested without rendering a view or reaching for Lottie's.
enum AstronautMotion: Equatable {
    case looping
    case still

    /// Reduce Motion wins over playback: a track playing does not license
    /// motion the reader has asked the system not to show them.
    init(isPlaying: Bool, reduceMotion: Bool) {
        self = isPlaying && !reduceMotion ? .looping : .still
    }

    /// Pausing on the current frame rather than rewinding means a track paused
    /// and resumed picks the astronaut up where it left off.
    var lottieMode: LottiePlaybackMode {
        switch self {
        case .looping: .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
        case .still: .paused
        }
    }
}

/// Decodes the astronaut once per launch.
///
/// `LottieAnimation` is `Sendable`, so the decode happens off the main actor
/// and the result crosses back as a value. The cache exists because the Media
/// panel is built and torn down every time the notch expands.
@MainActor
enum AstronautAnimation {
    private static var cached: LottieAnimation?
    private static var didReportMiss = false

    static func load() async -> LottieAnimation? {
        if let cached { return cached }
        guard let url = AnimationLocator.locate(AnimationLocator.astronautName) else {
            reportMissOnce("no animation bundled at \(AnimationLocator.astronautName).json")
            return nil
        }
        let decoded = await Task.detached(priority: .utility) { decode(url) }.value
        cached = decoded
        return decoded
    }

    /// How long the artwork at `url` runs, or nil when it is not a Lottie
    /// file at all. Internal so the suite can pin the vendored asset without
    /// taking a direct dependency on Lottie's types.
    nonisolated static func duration(of url: URL) -> TimeInterval? {
        decode(url)?.duration
    }

    private nonisolated static func decode(_ url: URL) -> LottieAnimation? {
        do {
            return try JSONDecoder().decode(LottieAnimation.self, from: Data(contentsOf: url))
        } catch {
            NSLog("NotchHub animation: %@", error.localizedDescription)
            return nil
        }
    }

    /// Once per launch: the panel opens often, and a missing decoration should
    /// not fill the log.
    private static func reportMissOnce(_ message: String) {
        guard !didReportMiss else { return }
        didReportMiss = true
        NSLog("NotchHub animation: %@", message)
    }
}
