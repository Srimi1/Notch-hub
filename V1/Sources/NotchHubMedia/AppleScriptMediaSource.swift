@preconcurrency import AppKit
import Foundation

enum AppleScriptExecutionResult: Equatable, Sendable {
    case success([String])
    case denied
    case timedOut
    case targetUnavailable
    case failed
}

protocol AppleScriptExecuting: Sendable {
    func execute(_ source: String) async -> AppleScriptExecutionResult
}

actor SystemAppleScriptExecutor: AppleScriptExecuting {
    func execute(_ source: String) -> AppleScriptExecutionResult {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return Self.failure(from: errorInfo)
        }
        guard descriptor.numberOfItems > 0 else { return .success([]) }
        let values = (1 ... descriptor.numberOfItems).map { index in
            descriptor.atIndex(index)?.stringValue ?? ""
        }
        return .success(values)
    }

    private static func failure(from information: NSDictionary) -> AppleScriptExecutionResult {
        let code = (information[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        switch code {
        case -1743: return .denied
        case -1712: return .timedOut
        case -600: return .targetUnavailable
        default: return .failed
        }
    }
}

@MainActor
final class AppleScriptMediaSource: MediaSource {
    enum Player: String, CaseIterable, Sendable {
        case music = "Music"
        case spotify = "Spotify"

        var bundleIdentifier: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    private(set) var nowPlaying: MediaNowPlaying?
    private(set) var automationDenied = false
    private(set) var readIssue: String?
    private(set) var controlIssue: String?
    var onChange: (@MainActor @Sendable () -> Void)?
    var onDiagnostic: (@MainActor @Sendable (MediaDiagnostic) -> Void)?

    var isPolling: Bool { pollTask != nil }

    private let executor: any AppleScriptExecuting
    private let runningBundleIdentifiers: @MainActor @Sendable () -> Set<String>
    private let pollInterval: Duration
    private let controlIssueSleep: @Sendable (Duration) async throws -> Void
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var controlIssueExpiryTask: Task<Void, Never>?
    private var generation = 0
    private var isQuerying = false
    private var readDiagnosticState = ReadDiagnosticState.healthy

    init(
        executor: any AppleScriptExecuting = SystemAppleScriptExecutor(),
        pollInterval: Duration = .seconds(2),
        runningBundleIdentifiers: @escaping @MainActor @Sendable () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        controlIssueSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.executor = executor
        self.pollInterval = pollInterval
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.controlIssueSleep = controlIssueSleep
    }

    func start() {
        guard pollTask == nil else { return }
        generation += 1
        let activeGeneration = generation
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, generation == activeGeneration {
                await refresh(for: activeGeneration)
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        commandTask?.cancel()
        commandTask = nil
        controlIssueExpiryTask?.cancel()
        controlIssueExpiryTask = nil
        isQuerying = false
        readDiagnosticState = .healthy
        update(nowPlaying: nil, denied: false, readIssue: nil, controlIssue: nil)
    }

    func send(_ command: MediaTransportCommand) {
        guard commandTask == nil,
              let track = nowPlaying,
              let player = Self.player(for: track)
        else { return }
        let activeGeneration = generation
        let executor = executor
        commandTask = Task { @MainActor [weak self] in
            let result = await executor.execute(Self.commandScript(command, player: player))
            guard let self, generation == activeGeneration, !Task.isCancelled else { return }
            commandTask = nil
            handleCommand(result)
            await refresh(for: activeGeneration)
        }
    }

    private func refresh(for activeGeneration: Int) async {
        guard !isQuerying else { return }
        isQuerying = true
        let players = Player.allCases.filter { runningBundleIdentifiers().contains($0.bundleIdentifier) }
        let outcome = await query(players)
        guard generation == activeGeneration, !Task.isCancelled else { return }
        isQuerying = false
        reportReadOutcome(outcome)
        update(
            nowPlaying: outcome.track,
            denied: outcome.denied,
            readIssue: outcome.issue,
            controlIssue: controlIssue
        )
    }

    private func query(_ players: [Player]) async -> QueryOutcome {
        var fallback: MediaNowPlaying?
        var denied = false
        var failed = false
        for player in players {
            switch await executor.execute(Self.queryScript(for: player)) {
            case let .success(values):
                guard let track = Self.parse(values, from: player) else { continue }
                if track.isPlaying { return QueryOutcome(track: track, denied: false, issue: nil) }
                if fallback == nil { fallback = track }
            case .denied:
                denied = true
            case .timedOut, .failed:
                failed = true
            case .targetUnavailable:
                continue
            }
        }
        let issue = failed && fallback == nil ? "Music or Spotify did not respond." : nil
        return QueryOutcome(track: fallback, denied: denied && fallback == nil, issue: issue)
    }

    private func handleCommand(_ result: AppleScriptExecutionResult) {
        switch result {
        case .success:
            updateControlIssue(nil)
        case .denied:
            updateControlIssue("Automation access is required for playback controls.")
            report(.warning, code: "control-denied", summary: "A media control was denied by macOS.")
        case .timedOut:
            updateControlIssue("The player did not respond.")
            report(.warning, code: "control-timeout", summary: "A media control timed out safely.")
        case .failed, .targetUnavailable:
            updateControlIssue("The player could not perform that control.")
            report(.warning, code: "control-failed", summary: "A media control failed safely.")
        }
    }

    private func reportReadOutcome(_ outcome: QueryOutcome) {
        let state: ReadDiagnosticState
        if outcome.denied {
            state = .denied
        } else if outcome.issue != nil {
            state = .failed
        } else {
            state = .healthy
        }
        guard state != readDiagnosticState else { return }
        readDiagnosticState = state
        switch state {
        case .healthy:
            return
        case .denied:
            report(.warning, code: "read-denied", summary: "macOS denied access to Music or Spotify playback.")
        case .failed:
            report(.warning, code: "read-failed", summary: "Music or Spotify did not answer a playback query.")
        }
    }

    private func update(
        nowPlaying: MediaNowPlaying?,
        denied: Bool,
        readIssue: String?,
        controlIssue: String?
    ) {
        let changed = self.nowPlaying != nowPlaying
            || automationDenied != denied
            || self.readIssue != readIssue
            || self.controlIssue != controlIssue
        self.nowPlaying = nowPlaying
        automationDenied = denied
        self.readIssue = readIssue
        self.controlIssue = controlIssue
        if changed { onChange?() }
    }

    private func updateControlIssue(_ issue: String?) {
        controlIssueExpiryTask?.cancel()
        controlIssueExpiryTask = nil
        let changed = controlIssue != issue
        controlIssue = issue
        if issue != nil { scheduleControlIssueExpiry(for: generation) }
        if changed { onChange?() }
    }

    private func scheduleControlIssueExpiry(for activeGeneration: Int) {
        let sleep = controlIssueSleep
        controlIssueExpiryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(5))
            } catch {
                return
            }
            guard let self, generation == activeGeneration, !Task.isCancelled else { return }
            controlIssueExpiryTask = nil
            guard controlIssue != nil else { return }
            controlIssue = nil
            onChange?()
        }
    }

    private func report(_ severity: MediaDiagnosticSeverity, code: String, summary: String) {
        onDiagnostic?(MediaDiagnostic(severity: severity, code: code, summary: summary))
    }
}

private extension AppleScriptMediaSource {
    enum ReadDiagnosticState: Equatable {
        case healthy
        case denied
        case failed
    }

    struct QueryOutcome: Sendable {
        let track: MediaNowPlaying?
        let denied: Bool
        let issue: String?
    }

    static func player(for track: MediaNowPlaying) -> Player? {
        Player.allCases.first { $0.bundleIdentifier == track.bundleIdentifier }
    }

    static func queryScript(for player: Player) -> String {
        """
        with timeout of 5 seconds
            tell application id "\(player.bundleIdentifier)"
                if it is running then
                    set playbackState to (player state as text)
                    try
                        set trackTitle to name of current track
                        set trackArtist to artist of current track
                        set trackAlbum to album of current track
                    on error
                        set trackTitle to ""
                        set trackArtist to ""
                        set trackAlbum to ""
                    end try
                    return {playbackState, trackTitle, trackArtist, trackAlbum}
                end if
                return {"stopped", "", "", ""}
            end tell
        end timeout
        """
    }

    static func commandScript(_ command: MediaTransportCommand, player: Player) -> String {
        let statement = switch command {
        case .previous: "previous track"
        case .playPause: "playpause"
        case .next: "next track"
        }
        return """
        with timeout of 5 seconds
            tell application id "\(player.bundleIdentifier)" to \(statement)
        end timeout
        """
    }

    static func parse(_ values: [String], from player: Player) -> MediaNowPlaying? {
        guard values.count == 4 else { return nil }
        let title = MediaTextSanitizer.display(values[1], maximumLength: 160)
        guard !title.isEmpty else { return nil }
        return MediaNowPlaying(
            title: title,
            artist: values[2],
            album: values[3],
            appName: player.rawValue,
            bundleIdentifier: player.bundleIdentifier,
            isPlaying: values[0] == "playing"
        )
    }
}
