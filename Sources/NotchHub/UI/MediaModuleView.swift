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
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
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

    /// How much of the 1000x1000 canvas the astronaut itself occupies.
    ///
    /// The rest is stars and music notes scattered to the edges. In the notch
    /// there is room for about 22 points, and at that size the whole
    /// composition is a smudge: the figure lands around nine points tall and
    /// the stars fall under a pixel. Drawing it large and showing only this
    /// much of it gives the figure the whole slot. The panel has room for
    /// all of it and shows all of it.
    static let figureFraction: CGFloat = 0.46

    /// Whether the music is actually playing. The astronaut listens along, so
    /// it moves while the track does and settles when the track is paused.
    var isPlaying: Bool
    /// The panel draws the whole composition on its light tile; the notch
    /// draws the figure alone, in white, straight onto the black.
    var ink: AstronautAnimation.Ink = .asDrawn
    var cropsToFigure = false
    /// Drawn instead when the artwork is not in the bundle. The panel is
    /// content to show nothing there, because the track details sit beside it
    /// and say what is playing. The notch wing has only this slot, so it falls
    /// back to the symbol it replaced rather than to a hole.
    var fallbackSymbol: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: LottieAnimation?

    var body: some View {
        Group {
            if let animation {
                if cropsToFigure {
                    figure(animation)
                } else {
                    player(animation)
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: NotchTheme.cardRadius).fill(Self.tile)
                        )
                }
            } else if let fallbackSymbol {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ActivityKind.media.tint)
            } else {
                Color.clear
            }
        }
        .task { animation = await AstronautAnimation.load(ink) }
        .accessibilityHidden(true)
    }

    /// The figure alone, filling the slot: drawn oversized and clipped, rather
    /// than by editing the artwork, so the panel and the notch stay one file.
    private func figure(_ animation: LottieAnimation) -> some View {
        GeometryReader { proxy in
            let slot = min(proxy.size.width, proxy.size.height)
            player(animation)
                .frame(width: slot / Self.figureFraction, height: slot / Self.figureFraction)
                .offset(
                    x: -(slot / Self.figureFraction - slot) / 2,
                    y: -(slot / Self.figureFraction - slot) / 2
                )
        }
        .clipped()
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

    /// Which ground the astronaut is going to be drawn on.
    enum Ink {
        /// As authored, for the panel's light tile.
        case asDrawn
        /// Inverted, for the black collapsed pill.
        case white
    }

    private static var cached: [Ink: LottieAnimation] = [:]
    private static var didReportMiss = false

    static func load(_ ink: Ink = .asDrawn) async -> LottieAnimation? {
        if let cached = cached[ink] { return cached }
        guard let url = AnimationLocator.locate(AnimationLocator.astronautName) else {
            reportMissOnce("no animation bundled at \(AnimationLocator.astronautName).json")
            return nil
        }
        let decoded = await Task.detached(priority: .utility) { decode(url, ink: ink) }.value
        cached[ink] = decoded
        return decoded
    }

    /// How long the artwork at `url` runs, or nil when it is not a Lottie
    /// file at all. Internal so the suite can pin the vendored asset without
    /// taking a direct dependency on Lottie's types.
    nonisolated static func duration(of url: URL) -> TimeInterval? {
        decode(url)?.duration
    }

    private nonisolated static func decode(_ url: URL, ink: Ink = .asDrawn) -> LottieAnimation? {
        do {
            var data = try Data(contentsOf: url)
            if ink == .white { data = try inverted(data) }
            return try JSONDecoder().decode(LottieAnimation.self, from: data)
        } catch {
            NSLog("NotchHub animation: %@", error.localizedDescription)
            return nil
        }
    }

    /// The two-tone artwork with its tones swapped, for drawing on black.
    ///
    /// The file is drawn for a light ground in exactly two fills: a near-black
    /// for the figure, the stars and the notes, and white for the highlight cut
    /// into the helmet and the visor. Swapping them keeps the relationship the
    /// artist drew — a light figure with dark cutouts — rather than repainting
    /// every fill one colour, which is what a Lottie colour value provider
    /// keyed on the fill would do, and which would flatten the helmet away.
    ///
    /// Anything that is neither tone is left alone, so a future revision of the
    /// artwork degrades to "some of it inverted" rather than to nonsense.
    nonisolated static func inverted(_ json: Data) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: json)
        let swapped = swapTones(in: root)
        return try JSONSerialization.data(withJSONObject: swapped)
    }

    /// Bodymovin holds a solid fill as `{"c": {"k": [r, g, b, a]}}`, in 0...1.
    private nonisolated static func swapTones(in node: Any) -> Any {
        if let dictionary = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = key == "k" ? swapChannels(in: value) : swapTones(in: value)
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { swapTones(in: $0) }
        }
        return node
    }

    private nonisolated static func swapChannels(in value: Any) -> Any {
        guard let channels = value as? [Any], channels.count >= 3 else { return value }
        let numbers = channels.prefix(3).compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 3 else { return value }

        // 0x19/0x0C/0x23 and white, matched loosely: the file stores them as
        // floats, and an exact comparison would miss a re-export that rounds.
        let isNearBlack = numbers.allSatisfy { $0 < 0.2 }
        let isWhite = numbers.allSatisfy { $0 > 0.8 }
        guard isNearBlack || isWhite else { return value }

        let replacement: [Double] = isNearBlack ? [1, 1, 1] : [0, 0, 0]
        var result = channels
        for index in 0 ..< 3 { result[index] = replacement[index] }
        return result
    }

    /// Once per launch: the panel opens often, and a missing decoration should
    /// not fill the log.
    private static func reportMissOnce(_ message: String) {
        guard !didReportMiss else { return }
        didReportMiss = true
        NSLog("NotchHub animation: %@", message)
    }
}
