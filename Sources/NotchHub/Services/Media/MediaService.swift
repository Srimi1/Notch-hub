import Foundation

/// Now-Playing for the collapsed strip and the Media module.
///
/// Two sources, deliberately. Apple Events read Music and Spotify precisely but
/// need a permission the user can refuse and macOS never re-asks for. The
/// MediaRemote adapter needs no permission and sees *every* player — YouTube
/// Music in a browser tab, an Electron client, a web app — but leans on a
/// private framework Apple has already broken once and could break again.
///
/// So neither is the fallback for the other in the usual sense: whichever can
/// answer, answers, and transport is routed back to whichever one did.
@MainActor
final class MediaService: ObservableObject {

    /// Kept so `MediaService.NowPlaying` still names the shared type after the
    /// split into sources.
    typealias NowPlaying = NotchHub.NowPlaying

    /// Which source produced `nowPlaying`. Transport has to go back to the same
    /// one: telling Spotify to `playpause` over Apple Events does nothing for a
    /// browser tab, and a MediaRemote command aimed at the system does not
    /// necessarily land on the player the user is looking at.
    enum Source: Equatable {
        case none
        case appleScript
        case adapter
    }

    @Published private(set) var nowPlaying: NowPlaying?
    /// Set when macOS refused the Apple Event rather than the player being idle.
    @Published private(set) var automationDenied = false
    private(set) var source: Source = .none

    private let appleScript: AppleScriptMediaSource
    private let adapter: MediaRemoteAdapterSource?

    /// The shipping configuration: script the two players macOS lets us script,
    /// and read everything else through the bundled adapter when it is there.
    convenience init() {
        self.init(
            appleScript: AppleScriptMediaSource(),
            adapter: MediaRemoteAdapterSource.bundled()
        )
    }

    init(appleScript: AppleScriptMediaSource, adapter: MediaRemoteAdapterSource?) {
        self.appleScript = appleScript
        self.adapter = adapter
        appleScript.onChange = { [weak self] in self?.recompute() }
        adapter?.onChange = { [weak self] in self?.recompute() }
    }

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }

    /// True when system-wide playback can be read, which is what decides
    /// whether an empty Media module means "nothing is playing anywhere" or
    /// only "nothing is playing in Music or Spotify".
    var readsEveryPlayer: Bool {
        guard let adapter else { return false }
        return !adapter.isUnavailable
    }

    /// User-facing explanation when media state cannot be read at all.
    var unavailableReason: String? {
        guard nowPlaying == nil else { return nil }
        return Self.unavailableMessage(
            automationDenied: automationDenied,
            readsEveryPlayer: readsEveryPlayer
        )
    }

    /// What to say when there is simply nothing to show.
    var emptyHint: String {
        readsEveryPlayer
            ? "Play something — it shows up here."
            : "Play something in Music or Spotify."
    }

    nonisolated static func unavailableMessage(
        automationDenied: Bool,
        readsEveryPlayer: Bool
    ) -> String? {
        // While system playback is readable an empty module is honest: nothing
        // is playing. Complaining about Automation there would be noise about a
        // permission the user no longer needs.
        guard !readsEveryPlayer else { return nil }
        guard automationDenied else { return nil }
        return "NotchHub needs Automation access to read Music and Spotify. "
            + "Enable it in System Settings ▸ Privacy & Security ▸ Automation."
    }

    // MARK: - Lifecycle

    func start() {
        appleScript.start()
        adapter?.start()
        recompute()
    }

    func stop() {
        appleScript.stop()
        adapter?.stop()
        // Nothing polls any more, so whatever was showing can never be
        // corrected. Hiding the Media module used to leave the last track
        // pinned in the notch as a foreground activity — outranking everything
        // else — for the rest of the session, long after the player had quit.
        recompute()
    }

    // MARK: - Transport

    func playPause() { activeSource?.playPause() }
    func next() { activeSource?.next() }
    func previous() { activeSource?.previous() }

    private var activeSource: MediaSource? {
        switch source {
        case .none: nil
        case .appleScript: appleScript
        case .adapter: adapter
        }
    }

    // MARK: - Selection

    /// A scripted player that is actually playing wins: it is the most precise
    /// reading available and its transport is exact. Otherwise anything the
    /// system reports beats a paused Spotify sitting in the background.
    nonisolated static func choose(
        scripted: NowPlaying?,
        system: NowPlaying?
    ) -> (source: Source, nowPlaying: NowPlaying?) {
        if let scripted, scripted.isPlaying { return (.appleScript, scripted) }
        if let system { return (.adapter, system) }
        if let scripted { return (.appleScript, scripted) }
        return (.none, nil)
    }

    private func recompute() {
        let choice = Self.choose(
            scripted: appleScript.nowPlaying,
            system: adapter?.nowPlaying
        )
        source = choice.source
        if nowPlaying != choice.nowPlaying { nowPlaying = choice.nowPlaying }
        if automationDenied != appleScript.automationDenied {
            automationDenied = appleScript.automationDenied
        }
    }
}
