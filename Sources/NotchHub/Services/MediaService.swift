import AppKit
import Combine
import Foundation

/// Now-Playing for the collapsed strip and Media module.
///
/// macOS locks the private MediaRemote framework behind an entitlement that
/// only Apple-signed (or specially-provisioned) apps get — which is why
/// MacNotch bundles a `mediaremote-adapter.pl` helper. Without that entitlement
/// the portable, no-helper path is scripting the two dominant players
/// (Apple Music + Spotify) over Apple Events. That's what we do here: poll
/// whichever is running and playing, and drive transport via the same channel.
///
/// First use triggers a one-time "control Music/Spotify" automation prompt.
final class MediaService: ObservableObject {

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var album: String
        var app: Player
        var isPlaying: Bool
    }

    enum Player: String {
        case music = "Music"
        case spotify = "Spotify"

        var bundleId: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    @Published private(set) var nowPlaying: NowPlaying?
    /// Set when macOS refused the Apple Event rather than the player being idle.
    ///
    /// These two states used to be indistinguishable: a denied Automation
    /// prompt discarded the error and produced `nil`, which the UI rendered as
    /// "Play something in Music or Spotify" — forever, while music was audibly
    /// playing. macOS never re-prompts, so without surfacing this there is no
    /// way for the user to learn what happened or how to fix it.
    @Published private(set) var automationDenied = false

    private var timer: Timer?

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }

    /// User-facing explanation when media state cannot be read at all.
    var unavailableReason: String? {
        guard automationDenied else { return nil }
        return "NotchHub needs Automation access to read Music and Spotify. "
            + "Enable it in System Settings ▸ Privacy & Security ▸ Automation."
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Transport

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ command: String) {
        guard let player = nowPlaying?.app else { return }
        run("tell application \"\(player.rawValue)\" to \(command)")
        // Reflect the change immediately rather than waiting for the next poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    // MARK: - Polling

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let outcome = self.query()
            DispatchQueue.main.async {
                if self.nowPlaying != outcome.nowPlaying { self.nowPlaying = outcome.nowPlaying }
                if self.automationDenied != outcome.denied { self.automationDenied = outcome.denied }
            }
        }
    }

    private struct QueryOutcome {
        var nowPlaying: NowPlaying?
        /// True only when a running player refused the Apple Event.
        var denied: Bool
    }

    /// Prefer a player that is actively playing; otherwise the one that's
    /// merely running and has a loaded track.
    private func query() -> QueryOutcome {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        var fallback: NowPlaying?
        var denied = false
        for player in [Player.music, Player.spotify] where running.contains(player.bundleId) {
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

    private enum PlayerQuery {
        case success(NowPlaying?)
        /// macOS refused the Apple Event — the user denied Automation access.
        case denied
        /// Any other failure (player quit mid-query, malformed reply).
        case failed
    }

    private func queryPlayer(_ player: Player) -> PlayerQuery {
        // Single round-trip: state + track fields joined by a delimiter.
        let script = """
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
        switch run(script) {
        case .denied: return .denied
        case .failed: return .failed
        case let .success(output):
            let parts = (output ?? "").components(separatedBy: "‖")
            guard parts.count == 4 else { return .failed }
            let state = parts[0]
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .success(nil) }
            return .success(NowPlaying(
                title: title,
                artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
                app: player,
                isPlaying: state == "playing"
            ))
        }
    }

    private enum ScriptResult {
        case success(String?)
        case denied
        case failed
    }

    /// AppleScript error codes that mean "macOS refused this", not "the script
    /// went wrong". `-1743` is `errAEEventNotPermitted` — the user declined the
    /// Automation prompt. `-600` is `procNotFound`, which the Apple Events
    /// machinery also reports when access is blocked before the target is
    /// reached.
    private static let permissionErrorCodes: Set<Int> = [-1743, -600]

    @discardableResult
    private func run(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let descriptor = script.executeAndReturnError(&error)

        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if let code, Self.permissionErrorCodes.contains(code) {
                NSLog("NotchHub media: Automation access denied (AppleScript %d)", code)
                return .denied
            }
            NSLog("NotchHub media: script failed (%@)", String(describing: code ?? 0))
            return .failed
        }
        return .success(descriptor.stringValue)
    }
}
