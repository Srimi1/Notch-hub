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

    private var timer: Timer?

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }

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
            let result = self?.query()
            DispatchQueue.main.async {
                if self?.nowPlaying != result { self?.nowPlaying = result }
            }
        }
    }

    /// Prefer a player that is actively playing; otherwise the one that's
    /// merely running and has a loaded track.
    private func query() -> NowPlaying? {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        var fallback: NowPlaying?
        for player in [Player.music, Player.spotify] where running.contains(player.bundleId) {
            guard let np = queryPlayer(player) else { continue }
            if np.isPlaying { return np }
            if fallback == nil { fallback = np }
        }
        return fallback
    }

    private func queryPlayer(_ player: Player) -> NowPlaying? {
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
        guard let output = run(script) else { return nil }
        let parts = output.components(separatedBy: "‖")
        guard parts.count == 4 else { return nil }
        let state = parts[0]
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return NowPlaying(
            title: title,
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            app: player,
            isPlaying: state == "playing"
        )
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor.stringValue
    }
}
