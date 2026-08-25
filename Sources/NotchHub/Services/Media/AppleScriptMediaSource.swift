import AppKit
import Foundation

/// Reads Apple Music and Spotify over Apple Events.
///
/// This is the exact path NotchHub shipped with, kept because it is the only
/// one that survives Apple breaking the private MediaRemote framework — which
/// has already happened once, in macOS 15.4. It sees two players and needs the
/// user's Automation permission; the adapter source sees everything and needs
/// none. Neither is a superset of the other, so both stay.
@MainActor
final class AppleScriptMediaSource: MediaSource {

    enum Player: String, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"

        var bundleId: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    private(set) var nowPlaying: NowPlaying?
    var onChange: (() -> Void)?

    /// Set when macOS refused the Apple Event rather than the player being idle.
    ///
    /// These two states used to be indistinguishable: a denied Automation
    /// prompt discarded the error and produced `nil`, which the UI rendered as
    /// "Play something in Music or Spotify" — forever, while music was audibly
    /// playing. macOS never re-prompts, so without surfacing this there is no
    /// way for the user to learn what happened or how to fix it.
    private(set) var automationDenied = false

    nonisolated static let pollInterval: TimeInterval = 2.0

    /// Whether the Apple Events poll loop is running. Surfaced because whether
    /// this half has started is exactly what separates ambient media from the
    /// permission-prompting kind.
    var isPolling: Bool { pollTask != nil }

    private var pollTask: Task<Void, Never>?
    private var isQuerying = false

    /// NSAppleScript is not thread-safe and each call blocks for as long as the
    /// target app takes to answer. One serial queue, off the main thread.
    private nonisolated static let scriptQueue = DispatchQueue(
        label: "com.notchhub.media.applescript",
        qos: .utility
    )

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        // A track nobody is polling any more is not news, it is a leftover.
        if nowPlaying != nil || automationDenied {
            nowPlaying = nil
            automationDenied = false
            onChange?()
        }
    }

    // MARK: - Transport

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ command: String) {
        guard let player = nowPlaying.flatMap(Self.player(for:)) else { return }
        Task { [weak self] in
            _ = await Self.runOffMain("tell application \"\(player.rawValue)\" to \(command)")
            // Reflect the change immediately rather than waiting for the next poll.
            await self?.refresh()
        }
    }

    /// Transport only works for the two players this source actually drives; a
    /// track that came from anywhere else must not be sent Apple Events.
    nonisolated static func player(for nowPlaying: NowPlaying) -> Player? {
        Player.allCases.first { $0.bundleId == nowPlaying.app.bundleId }
    }

    // MARK: - Polling

    private func refresh() async {
        guard !isQuerying else { return }
        isQuerying = true
        defer { isQuerying = false }

        let outcome = await Self.queryOffMain()
        var changed = false
        if nowPlaying != outcome.nowPlaying {
            nowPlaying = outcome.nowPlaying
            changed = true
        }
        // A denial is a change too. Reporting only track changes meant a
        // refused Apple Event sat unpublished until something happened to start
        // playing — which, with Automation denied, it never would.
        if automationDenied != outcome.denied {
            automationDenied = outcome.denied
            changed = true
        }
        if changed { onChange?() }
    }

    struct QueryOutcome: Equatable, Sendable {
        var nowPlaying: NowPlaying?
        /// True only when a running player refused the Apple Event.
        var denied: Bool
    }

    private nonisolated static func queryOffMain() async -> QueryOutcome {
        await withCheckedContinuation { continuation in
            scriptQueue.async { continuation.resume(returning: query()) }
        }
    }

    private nonisolated static func runOffMain(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            scriptQueue.async { continuation.resume(returning: run(source)) }
        }
    }

    /// Prefer a player that is actively playing; otherwise the one that's
    /// merely running and has a loaded track.
    private nonisolated static func query() -> QueryOutcome {
        let running = runningBundleIds()
        var fallback: NowPlaying?
        var denied = false
        for player in Player.allCases where running.contains(player.bundleId) {
            switch queryPlayer(player) {
            case let .success(track):
                guard let track else { continue }
                if track.isPlaying { return QueryOutcome(nowPlaying: track, denied: false) }
                if fallback == nil { fallback = track }
            case .denied:
                denied = true
            case .failed:
                continue
            }
        }
        // A denial only matters while we have nothing to show; if the other
        // player answered, the user still gets real state.
        return QueryOutcome(nowPlaying: fallback, denied: denied && fallback == nil)
    }

    private nonisolated static func runningBundleIds() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    enum PlayerQuery: Equatable {
        case success(NowPlaying?)
        /// macOS refused the Apple Event — the user denied Automation access.
        case denied
        /// Any other failure (player quit mid-query, malformed reply).
        case failed
    }

    private nonisolated static func queryPlayer(_ player: Player) -> PlayerQuery {
        switch run(script(for: player)) {
        case .denied: return .denied
        case .failed: return .failed
        case let .success(output): return parse(output, from: player)
        }
    }

    /// Single round-trip: state + track fields joined by a delimiter.
    nonisolated static func script(for player: Player) -> String {
        """
        tell application "\(player.rawValue)"
            if it is running then
                set st to (player state as text)
                try
                    set t to name of current track
                    set a to artist of current track
                    set al to album of current track
                on error
                    set t to ""
                    set a to ""
                    set al to ""
                end try
                return st & "‖" & t & "‖" & a & "‖" & al
            else
                return "stopped‖‖‖"
            end if
        end tell
        """
    }

    nonisolated static func parse(_ output: String?, from player: Player) -> PlayerQuery {
        let parts = (output ?? "").components(separatedBy: "‖")
        guard parts.count == 4 else { return .failed }
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .success(nil) }
        return .success(NowPlaying(
            title: title,
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            app: MediaApp(name: player.rawValue, bundleId: player.bundleId),
            isPlaying: parts[0] == "playing"
        ))
    }

    enum ScriptResult: Equatable, Sendable {
        case success(String?)
        case denied
        case failed
    }

    /// AppleScript error codes that mean "macOS refused this", not "the script
    /// went wrong". `-1743` is `errAEEventNotPermitted` — the user declined the
    /// Automation prompt. `-600` is `procNotFound`, which the Apple Events
    /// machinery also reports when access is blocked before the target is
    /// reached.
    nonisolated static let permissionErrorCodes: Set<Int> = [-1743, -600]

    @discardableResult
    private nonisolated static func run(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let descriptor = script.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if let code, permissionErrorCodes.contains(code) {
                NSLog("NotchHub media: Automation access denied (AppleScript %d)", code)
                return .denied
            }
            NSLog("NotchHub media: script failed (%@)", String(describing: code ?? 0))
            return .failed
        }
        return .success(descriptor.stringValue)
    }
}
