import Foundation
import Testing
@testable import NotchHub

/// The adapter is a child process that can die at any moment, on a private
/// framework Apple may remove. What matters is that dying is survivable: it
/// restarts, it backs off, and eventually it stops trying and says so instead
/// of spawning a process a second forever.
@Suite("Media adapter source")
@MainActor
struct MediaRemoteAdapterSourceTests {

    @Test
    func startingLaunchesTheStreamOnce() async {
        let launcher = FakeLauncher()
        let source = makeSource(launcher)

        source.start()
        source.start()
        await settle()

        #expect(launcher.state.launches.count == 1)
        #expect(launcher.state.launches.first == MediaRemoteAdapterSource.streamArguments)
    }

    @Test
    func aTrackLineBecomesNowPlayingAndNotifies() async {
        let launcher = FakeLauncher()
        let changes = Counter()
        let source = makeSource(launcher)
        source.onChange = { changes.value += 1 }

        source.start()
        await settle()
        launcher.emit(.line(trackLine(title: "Nightcall", playing: true)))
        await settle()

        #expect(source.nowPlaying?.title == "Nightcall")
        #expect(source.nowPlaying?.app.name == "Test Player")
        #expect(source.nowPlaying?.isPlaying == true)
        #expect(changes.value == 1)
    }

    /// Re-sending the identical state must not churn the UI: `--no-diff` means
    /// the adapter repeats the full payload on every update.
    @Test
    func anUnchangedPayloadDoesNotNotifyAgain() async {
        let launcher = FakeLauncher()
        let changes = Counter()
        let source = makeSource(launcher)
        source.onChange = { changes.value += 1 }

        source.start()
        await settle()
        launcher.emit(.line(trackLine(title: "Nightcall", playing: true)))
        launcher.emit(.line(trackLine(title: "Nightcall", playing: true)))
        await settle()

        #expect(changes.value == 1)
    }

    @Test
    func stoppingTerminatesTheProcessAndDoesNotRestartIt() async {
        let launcher = FakeLauncher()
        let source = makeSource(launcher)

        source.start()
        await settle()
        source.stop()
        launcher.emit(.exited(status: 0))
        await settle()

        #expect(launcher.state.handles.first?.terminateCount == 1)
        #expect(launcher.state.launches.count == 1)
        #expect(source.isUnavailable == false)
    }

    /// A crash is not fatal — the adapter comes back, and the delay grows so a
    /// permanently broken adapter is not a permanent process spawner.
    @Test
    func acrashRestartsWithGrowingBackoff() async {
        let launcher = FakeLauncher()
        let schedule = Schedule()
        let source = makeSource(launcher, schedule: schedule)

        source.start()
        await settle()
        launcher.emit(.exited(status: 1))
        await settle()
        launcher.emit(.exited(status: 1))
        await settle()

        #expect(launcher.state.launches.count == 3)
        #expect(schedule.delays == [1, 2])
        #expect(source.isUnavailable == false)
    }

    @Test
    func backoffDoublesAndThenStopsGrowing() {
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 1) == 1)
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 2) == 2)
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 5) == 16)
        #expect(
            MediaRemoteAdapterSource.restartDelay(afterFailures: 50)
                == MediaRemoteAdapterSource.maximumRestartDelay
        )
    }

    /// Apple breaking MediaRemote again should degrade NotchHub, not wedge it.
    @Test
    func repeatedCrashesGiveUpAndReportUnavailable() async {
        let launcher = FakeLauncher()
        let source = makeSource(launcher)

        source.start()
        await settle()
        for _ in 0 ..< MediaRemoteAdapterSource.maximumConsecutiveFailures {
            launcher.emit(.exited(status: 1))
            await settle()
        }

        #expect(source.isUnavailable)
        #expect(source.nowPlaying == nil)
        let launchesWhileGivingUp = launcher.state.launches.count
        source.start()
        await settle()
        #expect(launcher.state.launches.count == launchesWhileGivingUp)
    }

    /// A stream that produces data is healthy again, however badly it started.
    @Test
    func aWorkingRunClearsTheCrashCount() async {
        let launcher = FakeLauncher()
        let schedule = Schedule()
        let source = makeSource(launcher, schedule: schedule)

        source.start()
        await settle()
        launcher.emit(.exited(status: 1))
        await settle()
        launcher.emit(.line(trackLine(title: "Teardrop", playing: true)))
        launcher.emit(.exited(status: 1))
        await settle()

        #expect(schedule.delays == [1, 1])
        #expect(source.isUnavailable == false)
    }

    /// A launch that throws is a failure like any other, not a silent no-op
    /// that leaves the source permanently idle.
    @Test
    func afailedLaunchIsTreatedAsACrash() async {
        let launcher = FakeLauncher()
        launcher.state.failNextLaunch = true
        let schedule = Schedule()
        let source = makeSource(launcher, schedule: schedule)

        source.start()
        await settle()

        // The failure is counted and a restart scheduled; this scheduler runs
        // the work immediately, so the retry has already happened — and
        // succeeded, since only the first launch was rigged to throw.
        #expect(schedule.delays == [1])
        #expect(launcher.state.launches.count == 2)
        #expect(source.isUnavailable == false)
    }

    @Test
    func transportSendsTheDocumentedCommandIds() async {
        let launcher = FakeLauncher()
        let source = makeSource(launcher)

        source.start()
        await settle()
        source.playPause()
        source.next()
        source.previous()

        #expect(launcher.state.detached == [
            ["send", MediaRemoteAdapterSource.togglePlayPauseCommand],
            ["send", MediaRemoteAdapterSource.nextTrackCommand],
            ["send", MediaRemoteAdapterSource.previousTrackCommand]
        ])
    }

    /// Commands sent to an adapter that has given up would spawn a process per
    /// tap for nothing.
    @Test
    func anUnavailableAdapterSendsNothing() async {
        let launcher = FakeLauncher()
        let source = makeSource(launcher)

        source.start()
        await settle()
        for _ in 0 ..< MediaRemoteAdapterSource.maximumConsecutiveFailures {
            launcher.emit(.exited(status: 1))
            await settle()
        }
        source.playPause()

        #expect(launcher.state.detached.isEmpty)
    }

    // MARK: - Helpers

    private func makeSource(
        _ launcher: FakeLauncher,
        schedule: Schedule = Schedule()
    ) -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(
            launcher: launcher,
            schedule: { delay, work in
                schedule.delays.append(delay)
                work()
            },
            resolveApp: { bundleId, _ in MediaApp(name: "Test Player", bundleId: bundleId) }
        )
    }

    private func trackLine(title: String, playing: Bool) -> String {
        """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.example.player",\
        "playing":\(playing),"title":"\(title)","artist":"Kavinsky","album":"OutRun"}}
        """
    }

    /// The source drains its stream on a main-actor task; give it turns.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// Unchecked: these tests run entirely on the main actor, and the fakes are only
/// touched from there.
private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class Schedule: @unchecked Sendable {
    var delays: [TimeInterval] = []
}

private final class FakeLauncherState: @unchecked Sendable {
    var launches: [[String]] = []
    var detached: [[String]] = []
    var continuations: [AsyncStream<AdapterEvent>.Continuation] = []
    var handles: [FakeHandle] = []
    var failNextLaunch = false
}

private struct LaunchFailed: Error {}

private final class FakeLauncher: AdapterLaunching, @unchecked Sendable {
    let state = FakeLauncherState()

    func launch(arguments: [String]) throws -> AdapterSession {
        state.launches.append(arguments)
        if state.failNextLaunch {
            state.failNextLaunch = false
            throw LaunchFailed()
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AdapterEvent.self)
        state.continuations.append(continuation)
        let handle = FakeHandle()
        state.handles.append(handle)
        return AdapterSession(handle: handle, events: stream)
    }

    func runDetached(arguments: [String]) {
        state.detached.append(arguments)
    }

    /// Feed the most recently launched process. `.exited` finishes its stream,
    /// exactly as the real launcher does.
    func emit(_ event: AdapterEvent) {
        guard let continuation = state.continuations.last else { return }
        continuation.yield(event)
        if case .exited = event { continuation.finish() }
    }
}

private final class FakeHandle: AdapterProcessHandle, @unchecked Sendable {
    private(set) var isRunning = true
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

/// Two sources, one row in the UI. Which one wins decides both what the user
/// reads and where a tap on "next" is sent.
@Suite("Media source selection")
struct MediaSelectionTests {

    private func track(_ title: String, playing: Bool, app: String) -> NowPlaying {
        NowPlaying(
            title: title,
            artist: "",
            album: "",
            app: MediaApp(name: app, bundleId: app),
            isPlaying: playing
        )
    }

    /// A scripted player that is actually playing is the best reading we have,
    /// and its transport is exact rather than "whatever macOS thinks is front".
    @Test
    func aPlayingScriptedPlayerWins() {
        let choice = MediaService.choose(
            scripted: track("Spotify song", playing: true, app: "Spotify"),
            system: track("Browser song", playing: true, app: "Chrome")
        )
        #expect(choice.source == .appleScript)
        #expect(choice.nowPlaying?.title == "Spotify song")
    }

    /// The reason this feature exists: YouTube Music in a tab beats a Spotify
    /// window that is merely open with a paused track in it.
    @Test
    func systemPlaybackBeatsAnIdleScriptedPlayer() {
        let choice = MediaService.choose(
            scripted: track("Paused song", playing: false, app: "Spotify"),
            system: track("Browser song", playing: true, app: "Chrome")
        )
        #expect(choice.source == .adapter)
        #expect(choice.nowPlaying?.title == "Browser song")
    }

    @Test
    func anIdleScriptedPlayerIsBetterThanNothing() {
        let choice = MediaService.choose(
            scripted: track("Paused song", playing: false, app: "Spotify"),
            system: nil
        )
        #expect(choice.source == .appleScript)
        #expect(choice.nowPlaying?.title == "Paused song")
    }

    @Test
    func silenceEverywhereSelectsNoSource() {
        let choice = MediaService.choose(scripted: nil, system: nil)
        #expect(choice.source == .none)
        #expect(choice.nowPlaying == nil)
    }

    /// While system playback is readable, an empty module means silence — and
    /// nagging about an Automation permission the user no longer needs would be
    /// noise about a problem they do not have.
    @Test
    func automationIsOnlyExplainedWhenItStillMatters() {
        #expect(
            MediaService.unavailableMessage(automationDenied: true, readsEveryPlayer: true) == nil
        )
        #expect(
            MediaService.unavailableMessage(automationDenied: false, readsEveryPlayer: false) == nil
        )
        let message = MediaService.unavailableMessage(automationDenied: true, readsEveryPlayer: false)
        #expect(message?.contains("Automation") == true)
    }
}

/// The Apple Events path still carries Music and Spotify, and its single
/// round-trip reply is parsed by hand.
@Suite("AppleScript media parsing")
struct AppleScriptMediaParsingTests {

    @Test
    func aPlayingReplyBecomesATrack() {
        let parsed = AppleScriptMediaSource.parse("playing‖Nightcall‖Kavinsky‖OutRun", from: .spotify)
        guard case let .success(track) = parsed, let track else {
            Issue.record("expected a track, got \(parsed)")
            return
        }
        #expect(track.title == "Nightcall")
        #expect(track.artist == "Kavinsky")
        #expect(track.isPlaying)
        #expect(track.app.bundleId == "com.spotify.client")
        #expect(track.app.name == "Spotify")
    }

    @Test
    func anIdlePlayerReportsNoTrackRatherThanAnEmptyOne() {
        #expect(AppleScriptMediaSource.parse("stopped‖‖‖", from: .music) == .success(nil))
    }

    @Test
    func amalformedReplyIsAFailureNotABlankTrack() {
        #expect(AppleScriptMediaSource.parse("playing‖Nightcall", from: .music) == .failed)
        #expect(AppleScriptMediaSource.parse(nil, from: .music) == .failed)
    }

    /// Transport over Apple Events is only valid for the two apps this source
    /// drives; a browser tab must never be sent `playpause`.
    @Test
    func transportIsRefusedForPlayersThisSourceDoesNotDrive() {
        let scripted = NowPlaying(
            title: "x", artist: "", album: "",
            app: MediaApp(name: "Spotify", bundleId: "com.spotify.client"),
            isPlaying: true
        )
        let foreign = NowPlaying(
            title: "x", artist: "", album: "",
            app: MediaApp(name: "Chrome", bundleId: "com.google.Chrome"),
            isPlaying: true
        )
        #expect(AppleScriptMediaSource.player(for: scripted) == .spotify)
        #expect(AppleScriptMediaSource.player(for: foreign) == nil)
    }
}
