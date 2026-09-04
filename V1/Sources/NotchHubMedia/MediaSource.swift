import Foundation

@MainActor
protocol MediaSource: AnyObject {
    var nowPlaying: MediaNowPlaying? { get }
    var onChange: (@MainActor @Sendable () -> Void)? { get set }
    var onDiagnostic: (@MainActor @Sendable (MediaDiagnostic) -> Void)? { get set }

    func start()
    func stop()
    func send(_ command: MediaTransportCommand)
}

@MainActor
final class MediaService {
    private(set) var nowPlaying: MediaNowPlaying?
    private(set) var activeSource: MediaSourceIdentity = .none
    private(set) var controlIssue: String?

    var onChange: (@MainActor @Sendable () -> Void)?
    var onDiagnostic: (@MainActor @Sendable (MediaDiagnostic) -> Void)? {
        didSet { installDiagnosticHandlers() }
    }

    private let appleScript: AppleScriptMediaSource
    private let adapter: MediaRemoteAdapterSource?
    private var manualControlIssue: String?

    init(
        appleScript: AppleScriptMediaSource = AppleScriptMediaSource(),
        adapter: MediaRemoteAdapterSource? = MediaRemoteAdapterSource.bundled()
    ) {
        self.appleScript = appleScript
        self.adapter = adapter
        appleScript.onChange = { [weak self] in self?.recompute() }
        adapter?.onChange = { [weak self] in self?.recompute() }
    }

    var unavailableReason: String? {
        guard nowPlaying == nil else { return nil }
        if readsEveryPlayer { return nil }
        if appleScript.automationDenied {
            return "NotchHub needs Automation access to read Music and Spotify. "
                + "Enable it in System Settings ▸ Privacy & Security ▸ Automation."
        }
        if appleScript.isPolling, appleScript.readIssue != nil {
            return "Playback could not be read. Check that Music or Spotify is responding."
        }
        if adapter?.isUnavailable == true, !appleScript.isPolling {
            return "System playback is unavailable. Open Media to enable Music and Spotify."
        }
        return nil
    }

    var emptyHint: String {
        readsEveryPlayer
            ? "Play something — it shows up here."
            : "Play something in Music or Spotify."
    }

    var readsEveryPlayer: Bool {
        guard let adapter else { return false }
        return !adapter.isUnavailable
    }

    func startSystemPlayback() {
        adapter?.start()
        recompute()
    }

    func startScriptedPlayers() {
        appleScript.start()
        recompute()
    }

    func stop() {
        appleScript.stop()
        adapter?.stop()
        manualControlIssue = nil
        controlIssue = nil
        recompute()
    }

    func send(_ command: MediaTransportCommand) {
        manualControlIssue = nil
        switch activeSource {
        case .none:
            manualControlIssue = "No active player is available."
        case .appleScript:
            appleScript.send(command)
        case .adapter:
            adapter?.send(command)
        }
        recompute()
    }

    static func choose(
        scripted: MediaNowPlaying?,
        system: MediaNowPlaying?
    ) -> (source: MediaSourceIdentity, nowPlaying: MediaNowPlaying?) {
        if let scripted, scripted.isPlaying { return (.appleScript, scripted) }
        if let system { return (.adapter, system) }
        if let scripted { return (.appleScript, scripted) }
        return (.none, nil)
    }

    private func recompute() {
        let previousTrack = nowPlaying
        let previousSource = activeSource
        let previousIssue = controlIssue
        let choice = Self.choose(scripted: appleScript.nowPlaying, system: adapter?.nowPlaying)
        activeSource = choice.source
        nowPlaying = choice.nowPlaying
        if activeSource != .none {
            manualControlIssue = nil
        }
        controlIssue = sourceControlIssue ?? manualControlIssue
        if previousTrack != nowPlaying || previousSource != activeSource || previousIssue != controlIssue {
            onChange?()
        }
    }

    private var sourceControlIssue: String? {
        switch activeSource {
        case .none: nil
        case .appleScript: appleScript.controlIssue
        case .adapter: adapter?.controlIssue
        }
    }

    private func installDiagnosticHandlers() {
        appleScript.onDiagnostic = onDiagnostic
        adapter?.onDiagnostic = onDiagnostic
    }
}
