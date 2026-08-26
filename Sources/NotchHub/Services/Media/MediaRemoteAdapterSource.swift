import Foundation

/// Reads whatever macOS itself thinks is playing, via the bundled
/// mediaremote-adapter.
///
/// This is what makes YouTube Music — a browser tab or a web app, with no
/// AppleScript dictionary to interrogate — show up at all. It needs no
/// permission from the user, because nothing is being automated: a Perl process
/// reads the system's own now-playing state and prints JSON.
///
/// It is also the fragile half. The framework underneath is private, Apple has
/// already broken it once, and a future release may do so again. So this source
/// is built to fail quietly: a handful of crashes in a row and it marks itself
/// unavailable, leaving the AppleScript source to carry Music and Spotify.
@MainActor
final class MediaRemoteAdapterSource: MediaSource {

    private(set) var nowPlaying: NowPlaying?
    var onChange: (() -> Void)?

    /// The adapter kept dying. Reported so the UI can explain an empty state
    /// instead of implying nothing is playing.
    private(set) var isUnavailable = false

    /// `--no-diff` costs a slightly larger line per update and removes an entire
    /// class of bug: with diffing on, every payload is a patch against a
    /// remembered state, and one dropped line desynchronises the display until
    /// the track changes. `--no-artwork` keeps those lines small — NotchHub
    /// draws no artwork, and artwork is hundreds of kilobytes of base64.
    nonisolated static let streamArguments = ["stream", "--no-diff", "--no-artwork"]

    /// MediaRemote command ids, from the adapter's `send` table.
    nonisolated static let togglePlayPauseCommand = "2"
    nonisolated static let nextTrackCommand = "4"
    nonisolated static let previousTrackCommand = "5"

    nonisolated static let maximumConsecutiveFailures = 5
    nonisolated static let maximumRestartDelay: TimeInterval = 30

    /// How long a run has to last before it counts as healthy.
    nonisolated static let stabilityWindow: TimeInterval = 30

    private let launcher: AdapterLaunching
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let resolveApp: (_ bundleId: String?, _ parentBundleId: String?) -> MediaApp
    private let now: @Sendable () -> Date

    /// Whether the stream is up.
    var isStreaming: Bool { readTask != nil }

    private var processHandle: AdapterProcessHandle?
    private var readTask: Task<Void, Never>?
    private var isStopping = false
    private var consecutiveFailures = 0
    private var lastLaunchDate: Date?
    private var hasReapedStrays = false
    /// Guards the window between deciding to start and having something to show
    /// for it.
    ///
    /// `readTask` cannot be set until the process is launched, and launching is
    /// preceded by reaping strays — which waits on `pkill`, and waiting spins
    /// the run loop. Anything already queued on the main actor runs *inside*
    /// that wait, sees `readTask` still nil, and starts a second adapter. That
    /// is not hypothetical: the module-visibility subscriber fires on
    /// subscribe, and its work landed in exactly this gap, leaving two perl
    /// processes streaming the same data.
    private var isStarting = false

    init(
        launcher: AdapterLaunching,
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
            = { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
        resolveApp: @escaping (_ bundleId: String?, _ parentBundleId: String?) -> MediaApp
            = { MediaApp.resolve(bundleId: $0, parentBundleId: $1) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launcher = launcher
        self.schedule = schedule
        self.resolveApp = resolveApp
        self.now = now
    }

    /// `nil` when the adapter is not bundled — a plain `swift run`, or a bundle
    /// assembled without `scripts/build-app.sh`. Not an error state.
    static func bundled() -> MediaRemoteAdapterSource? {
        guard let paths = AdapterLocator.locate() else { return nil }
        return MediaRemoteAdapterSource(launcher: AdapterProcessLauncher(paths: paths))
    }

    // MARK: - Lifecycle

    func start() {
        guard !isUnavailable, readTask == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        isStopping = false
        // Before the first launch only, and before it rather than after: the
        // pattern it kills matches our own child too.
        if !hasReapedStrays {
            hasReapedStrays = true
            launcher.reapStrays()
        }
        launch()
    }

    func stop() {
        isStopping = true
        readTask?.cancel()
        readTask = nil
        processHandle?.terminate()
        processHandle = nil
        // Nothing is reading the stream any more, so the last track would sit
        // there being wrong for as long as the module stays off.
        update(nil)
    }

    private func launch() {
        do {
            lastLaunchDate = now()
            let session = try launcher.launch(arguments: Self.streamArguments)
            processHandle = session.handle
            readTask = Task { [weak self] in
                for await event in session.events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
        } catch {
            NSLog("NotchHub media adapter: launch failed (%@)", error.localizedDescription)
            handleExit(status: -1)
        }
    }

    private func handle(_ event: AdapterEvent) {
        switch event {
        case let .line(line): ingest(line)
        case let .exited(status): handleExit(status: status)
        }
    }

    private func ingest(_ line: String) {
        switch Self.parse(line: line) {
        case .ignored:
            return
        case .nothingPlaying:
            update(nil)
        case let .media(payload):
            update(NowPlaying(
                title: payload.title,
                artist: payload.artist,
                album: payload.album,
                app: resolveApp(payload.bundleId, payload.parentBundleId),
                isPlaying: payload.isPlaying
            ))
        }
    }

    private func handleExit(status: Int32) {
        processHandle = nil
        readTask = nil
        guard !isStopping else { return }

        let uptime = lastLaunchDate.map { now().timeIntervalSince($0) } ?? 0
        consecutiveFailures = Self.failures(
            afterExitWithUptime: uptime,
            previousFailures: consecutiveFailures
        )
        lastLaunchDate = nil
        update(nil)

        guard consecutiveFailures < Self.maximumConsecutiveFailures else {
            isUnavailable = true
            NSLog("NotchHub media adapter: gave up after %d failed runs (last status %d)",
                  consecutiveFailures, status)
            onChange?()
            return
        }

        NSLog("NotchHub media adapter: exited with %d, restarting (attempt %d)",
              status, consecutiveFailures)
        schedule(Self.restartDelay(afterFailures: consecutiveFailures)) {
            Task { @MainActor [weak self] in self?.restart() }
        }
    }

    private func restart() {
        guard !isStopping, !isUnavailable, readTask == nil else { return }
        launch()
    }

    /// The failure streak after a run ends. A run that lasted counts as
    /// healthy, so its exit is the first of a fresh streak; a short-lived one
    /// extends the streak it belongs to.
    ///
    /// Surviving, not speaking, is what makes a run healthy. Clearing the
    /// streak on any parsed line looks reasonable — the adapter is alive and
    /// talking — but the adapter's own output is drained on the way out, so a
    /// process that printed one good line and died still cleared the count.
    /// The ceiling was never reached, the source never went unavailable, and
    /// the relaunch loop ran for the rest of the session: a new track every
    /// second or so, and with it a collapsed pill growing and shrinking
    /// forever.
    nonisolated static func failures(
        afterExitWithUptime uptime: TimeInterval,
        previousFailures: Int
    ) -> Int {
        uptime >= stabilityWindow ? 1 : previousFailures + 1
    }

    /// Doubling backoff, capped. A player that never starts must not cost a
    /// process spawn every second for the rest of the session.
    nonisolated static func restartDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponential = pow(2.0, Double(failures - 1))
        return min(maximumRestartDelay, exponential)
    }

    private func update(_ next: NowPlaying?) {
        guard nowPlaying != next else { return }
        nowPlaying = next
        onChange?()
    }

    // MARK: - Transport

    func playPause() { send(Self.togglePlayPauseCommand) }
    func next() { send(Self.nextTrackCommand) }
    func previous() { send(Self.previousTrackCommand) }

    private func send(_ command: String) {
        guard !isUnavailable else { return }
        launcher.runDetached(arguments: ["send", command])
    }

    // MARK: - Parsing

    /// The fields NotchHub uses out of a stream payload, before any naming or
    /// display decisions are made.
    struct StreamPayload: Equatable {
        var title: String
        var artist: String
        var album: String
        var bundleId: String?
        var parentBundleId: String?
        var isPlaying: Bool
    }

    enum StreamLine: Equatable {
        case media(StreamPayload)
        /// The adapter answered, and nothing is playing.
        case nothingPlaying
        /// Not a payload line at all — noise, or a message shape we don't know.
        case ignored
    }

    nonisolated static func parse(line: String) -> StreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data"
        else { return .ignored }

        // A missing or misshapen payload is a message we do not understand, and
        // must not be read as "nothing is playing" — if upstream ever renames
        // the key, asserting silence would hide a playing track forever. An
        // empty payload, on the other hand, is upstream's documented way of
        // saying no player is reporting.
        guard let payload = object["payload"] as? [String: Any] else { return .ignored }
        guard !payload.isEmpty else { return .nothingPlaying }
        // Upstream guarantees title, playing and bundleIdentifier are non-null
        // whenever anything is playing, and prints media without a title as
        // invalid. Treat a missing title the same way rather than showing a
        // blank row.
        let title = (payload["title"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .nothingPlaying }

        return .media(StreamPayload(
            title: title,
            artist: (payload["artist"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            album: (payload["album"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            bundleId: payload["bundleIdentifier"] as? String,
            parentBundleId: payload["parentApplicationBundleIdentifier"] as? String,
            isPlaying: payload["playing"] as? Bool ?? false
        ))
    }
}
