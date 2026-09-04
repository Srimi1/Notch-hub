@preconcurrency import AppKit
import Foundation

@MainActor
final class MediaRemoteAdapterSource: MediaSource {
    static let streamArguments = ["stream", "--no-diff", "--no-artwork"]
    static let maximumConsecutiveFailures = 5
    static let maximumRestartDelay: TimeInterval = 30
    static let stabilityWindow: TimeInterval = 30

    private static let commandIdentifiers: [MediaTransportCommand: String] = [
        .playPause: "2",
        .next: "4",
        .previous: "5",
    ]

    private(set) var nowPlaying: MediaNowPlaying?
    private(set) var isUnavailable = false
    private(set) var controlIssue: String?
    var onChange: (@MainActor @Sendable () -> Void)?
    var onDiagnostic: (@MainActor @Sendable (MediaDiagnostic) -> Void)?

    var isStreaming: Bool { streamTask != nil }

    private let launcher: any AdapterLaunching
    private let resolveApplication: @MainActor @Sendable (String?, String?) -> MediaApplication
    private let now: @Sendable () -> Date
    private let restartSleep: @Sendable (Duration) async throws -> Void
    private let controlIssueSleep: @Sendable (Duration) async throws -> Void
    private var processHandle: (any AdapterProcessHandle)?
    private var commandHandle: (any AdapterProcessHandle)?
    private var streamTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var controlIssueExpiryTask: Task<Void, Never>?
    private var lastLaunchDate: Date?
    private var consecutiveFailures = 0
    private var generation = 0
    private var isStopping = false
    private var didReportDiscardedOutput = false
    private var didReportMalformedPayload = false

    init(
        launcher: any AdapterLaunching,
        resolveApplication: @escaping @MainActor @Sendable (String?, String?) -> MediaApplication = {
            MediaApplication.resolve(
                bundleIdentifier: $0,
                parentBundleIdentifier: $1,
                localizedName: { identifier in
                    NSRunningApplication
                        .runningApplications(withBundleIdentifier: identifier)
                        .compactMap(\.localizedName)
                        .first
                }
            )
        },
        now: @escaping @Sendable () -> Date = { Date() },
        restartSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        controlIssueSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.launcher = launcher
        self.resolveApplication = resolveApplication
        self.now = now
        self.restartSleep = restartSleep
        self.controlIssueSleep = controlIssueSleep
    }

    static func bundled() -> MediaRemoteAdapterSource? {
        guard let paths = AdapterLocator.locate() else { return nil }
        return MediaRemoteAdapterSource(launcher: AdapterProcessLauncher(paths: paths))
    }

    func start() {
        guard !isUnavailable, streamTask == nil, restartTask == nil else { return }
        isStopping = false
        generation += 1
        launch(for: generation)
    }

    func stop() {
        isStopping = true
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        streamTask?.cancel()
        streamTask = nil
        commandTask?.cancel()
        commandTask = nil
        controlIssueExpiryTask?.cancel()
        controlIssueExpiryTask = nil
        processHandle?.terminate()
        processHandle = nil
        commandHandle?.terminate()
        commandHandle = nil
        lastLaunchDate = nil
        updateTrack(nil)
        updateControlIssue(nil)
    }

    func send(_ command: MediaTransportCommand) {
        guard !isUnavailable, commandTask == nil,
              let identifier = Self.commandIdentifiers[command]
        else { return }
        do {
            let session = try launcher.launchCommand(arguments: ["send", identifier])
            let activeGeneration = generation
            commandHandle = session.handle
            commandTask = Task { @MainActor [weak self] in
                await self?.monitorCommand(session, generation: activeGeneration)
            }
        } catch {
            updateControlIssue("Playback control could not start.")
            report(.warning, code: "command-launch-failed", summary: "A media command could not start.")
        }
    }

    private func launch(for activeGeneration: Int) {
        do {
            lastLaunchDate = now()
            let session = try launcher.launchStream(arguments: Self.streamArguments)
            processHandle = session.handle
            streamTask = Task { @MainActor [weak self] in
                for await event in session.events {
                    guard let self, generation == activeGeneration, !Task.isCancelled else { return }
                    await handle(event, generation: activeGeneration)
                }
            }
        } catch {
            report(.error, code: "adapter-launch-failed", summary: "The media adapter could not start.")
            handleExit(status: -1, generation: activeGeneration)
        }
    }

    private func handle(_ event: AdapterEvent, generation activeGeneration: Int) async {
        switch event {
        case let .line(line):
            let parsed = await Task.detached(priority: .utility) {
                Self.parse(line: line)
            }.value
            guard generation == activeGeneration, !Task.isCancelled else { return }
            ingest(parsed)
        case .discardedOutput:
            guard !didReportDiscardedOutput else { return }
            didReportDiscardedOutput = true
            report(.warning, code: "adapter-output-discarded", summary: "Invalid media adapter output was discarded.")
        case let .exited(status):
            handleExit(status: status, generation: activeGeneration)
        }
    }

    private func ingest(_ line: StreamLine) {
        switch line {
        case .ignored:
            return
        case .malformed:
            guard !didReportMalformedPayload else { return }
            didReportMalformedPayload = true
            report(.warning, code: "adapter-payload-rejected", summary: "A media payload failed validation.")
        case .nothingPlaying:
            updateTrack(nil)
        case let .media(payload):
            let application = resolveApplication(payload.bundleIdentifier, payload.parentBundleIdentifier)
            updateTrack(MediaNowPlaying(
                title: payload.title,
                artist: payload.artist,
                album: payload.album,
                appName: application.name,
                bundleIdentifier: application.bundleIdentifier,
                isPlaying: payload.isPlaying
            ))
        }
    }

    private func handleExit(status: Int32, generation activeGeneration: Int) {
        guard generation == activeGeneration else { return }
        processHandle = nil
        streamTask = nil
        guard !isStopping else { return }
        let uptime = lastLaunchDate.map { now().timeIntervalSince($0) } ?? 0
        consecutiveFailures = Self.failures(
            afterExitWithUptime: uptime,
            previousFailures: consecutiveFailures
        )
        lastLaunchDate = nil
        updateTrack(nil)
        guard consecutiveFailures < Self.maximumConsecutiveFailures else {
            isUnavailable = true
            report(
                .error,
                code: "adapter-unavailable",
                summary: "System-wide media support stopped after repeated failures."
            )
            onChange?()
            return
        }
        report(
            .warning,
            code: "adapter-restarting",
            summary: "The media adapter exited and will restart with bounded backoff."
        )
        scheduleRestart(for: activeGeneration)
    }

    private func scheduleRestart(for activeGeneration: Int) {
        let delay = Self.restartDelay(afterFailures: consecutiveFailures)
        let sleep = restartSleep
        restartTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard let self, generation == activeGeneration, !isStopping, !Task.isCancelled else { return }
            restartTask = nil
            launch(for: activeGeneration)
        }
    }

    private func monitorCommand(_ session: AdapterCommandSession, generation activeGeneration: Int) async {
        let timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, generation == activeGeneration, commandHandle != nil else { return }
            session.handle.terminate()
        }
        var status: Int32?
        for await value in session.statuses {
            status = value
        }
        timeout.cancel()
        guard generation == activeGeneration, !Task.isCancelled else { return }
        commandHandle = nil
        commandTask = nil
        if status == 0 {
            updateControlIssue(nil)
        } else {
            updateControlIssue("The player could not perform that control.")
            report(.warning, code: "command-failed", summary: "A media command failed or timed out safely.")
        }
    }

    static func failures(afterExitWithUptime uptime: TimeInterval, previousFailures: Int) -> Int {
        uptime >= stabilityWindow ? 1 : previousFailures + 1
    }

    static func restartDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(maximumRestartDelay, pow(2, Double(failures - 1)))
    }

    private func updateTrack(_ track: MediaNowPlaying?) {
        guard nowPlaying != track else { return }
        nowPlaying = track
        onChange?()
    }
}

private extension MediaRemoteAdapterSource {
    func updateControlIssue(_ issue: String?) {
        controlIssueExpiryTask?.cancel()
        controlIssueExpiryTask = nil
        let changed = controlIssue != issue
        controlIssue = issue
        if issue != nil { scheduleControlIssueExpiry(for: generation) }
        if changed { onChange?() }
    }

    func scheduleControlIssueExpiry(for activeGeneration: Int) {
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

    func report(_ severity: MediaDiagnosticSeverity, code: String, summary: String) {
        onDiagnostic?(MediaDiagnostic(severity: severity, code: code, summary: summary))
    }
}

extension MediaRemoteAdapterSource {
    struct StreamPayload: Equatable, Sendable {
        let title: String
        let artist: String
        let album: String
        let bundleIdentifier: String?
        let parentBundleIdentifier: String?
        let isPlaying: Bool
    }

    enum StreamLine: Equatable, Sendable {
        case media(StreamPayload)
        case nothingPlaying
        case ignored
        case malformed
    }

    nonisolated static func parse(line: String) -> StreamLine {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
        guard line.utf8.count <= LineAccumulator.maximumBufferedBytes,
              let data = line.data(using: .utf8)
        else { return .malformed }
        let envelope: StreamEnvelope
        do {
            envelope = try JSONDecoder().decode(StreamEnvelope.self, from: data)
        } catch {
            return .malformed
        }
        guard envelope.type == "data" else { return .ignored }
        guard envelope.hasPayload, let payload = envelope.payload else { return .ignored }
        let title = MediaTextSanitizer.display(payload.title ?? "", maximumLength: 160)
        guard !title.isEmpty else { return .nothingPlaying }
        return .media(StreamPayload(
            title: title,
            artist: MediaTextSanitizer.display(payload.artist ?? "", maximumLength: 120),
            album: MediaTextSanitizer.display(payload.album ?? "", maximumLength: 160),
            bundleIdentifier: MediaTextSanitizer.bundleIdentifier(payload.bundleIdentifier),
            parentBundleIdentifier: MediaTextSanitizer.bundleIdentifier(payload.parentBundleIdentifier),
            isPlaying: payload.playing ?? false
        ))
    }
}

private struct StreamEnvelope: Decodable {
    let type: String?
    let payload: StreamPayloadObject?
    let hasPayload: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hasPayload = container.contains(.payload)
        payload = hasPayload ? try container.decode(StreamPayloadObject.self, forKey: .payload) : nil
    }
}

private struct StreamPayloadObject: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let bundleIdentifier: String?
    let parentBundleIdentifier: String?
    let playing: Bool?

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
        case bundleIdentifier
        case parentBundleIdentifier = "parentApplicationBundleIdentifier"
        case playing
    }
}
