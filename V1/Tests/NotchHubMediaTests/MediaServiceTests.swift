import Foundation
import Testing
@testable import NotchHubMedia

@MainActor
@Suite("Media source selection")
struct MediaSelectionTests {
    @Test("Playing scripted media has the highest priority")
    func playingScriptedSourceWins() {
        let choice = MediaService.choose(
            scripted: mediaTrack("Spotify song", playing: true, bundleIdentifier: "com.spotify.client"),
            system: mediaTrack("Browser song", playing: true)
        )

        #expect(choice.source == .appleScript)
        #expect(choice.nowPlaying?.title == "Spotify song")
    }

    @Test("System playback beats a paused scripted player")
    func systemSourceBeatsPausedScript() {
        let choice = MediaService.choose(
            scripted: mediaTrack("Paused song", playing: false, bundleIdentifier: "com.spotify.client"),
            system: mediaTrack("Browser song", playing: true)
        )

        #expect(choice.source == .adapter)
        #expect(choice.nowPlaying?.title == "Browser song")
    }

    @Test("Paused scripted media is retained when the system source is silent")
    func pausedScriptBeatsSilence() {
        let choice = MediaService.choose(
            scripted: mediaTrack("Paused song", playing: false, bundleIdentifier: "com.apple.Music"),
            system: nil
        )

        #expect(choice.source == .appleScript)
        #expect(choice.nowPlaying?.title == "Paused song")
    }

    @Test("Silence selects no source")
    func silenceSelectsNothing() {
        let choice = MediaService.choose(scripted: nil, system: nil)

        #expect(choice.source == .none)
        #expect(choice.nowPlaying == nil)
    }
}

@MainActor
@Suite("Media command routing")
struct MediaCommandRoutingTests {
    @Test("A system track routes controls through the adapter")
    func routesSystemControl() async throws {
        let launcher = FakeAdapterLauncher()
        let adapter = makeAdapter(launcher)
        let service = MediaService(appleScript: makeSilentScriptSource(), adapter: adapter)

        service.startSystemPlayback()
        try await settleMediaTasks()
        launcher.emitStream(.line(mediaAdapterLine(title: "Browser song", playing: true)))
        try await settleMediaTasks()
        service.send(.next)

        #expect(service.activeSource == .adapter)
        #expect(launcher.commandArguments == [["send", "4"]])
        launcher.finishCommand(status: 0)
        service.stop()
    }

    @Test("A playing scripted track routes a fixed AppleScript command")
    func routesScriptedControl() async throws {
        let executor = FakeAppleScriptExecutor(results: [
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
            .success([]),
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
        ])
        let source = makeScriptSource(executor: executor)
        let service = MediaService(appleScript: source, adapter: nil)

        service.startScriptedPlayers()
        try await settleMediaTasks()
        service.send(.next)
        try await settleMediaTasks()
        let scripts = await executor.sources()

        #expect(service.activeSource == .appleScript)
        #expect(scripts.count >= 2)
        #expect(scripts[1].contains("tell application id \"com.spotify.client\" to next track"))
        service.stop()
    }

    @Test("A later successful adapter command clears a prior visible failure")
    func clearsRecoveredControlFailure() async throws {
        let launcher = FakeAdapterLauncher()
        let adapter = makeAdapter(launcher)
        let service = MediaService(appleScript: makeSilentScriptSource(), adapter: adapter)

        service.startSystemPlayback()
        try await settleMediaTasks()
        launcher.emitStream(.line(mediaAdapterLine(title: "Browser song", playing: true)))
        try await settleMediaTasks()
        service.send(.next)
        launcher.finishCommand(status: 1)
        try await settleMediaTasks()
        #expect(service.controlIssue != nil)

        service.send(.next)
        launcher.finishCommand(status: 0)
        try await settleMediaTasks()
        #expect(service.controlIssue == nil)
        service.stop()
    }

    @Test("No active player yields a user-visible issue without launching a command")
    func reportsNoActivePlayer() {
        let launcher = FakeAdapterLauncher()
        let service = MediaService(
            appleScript: makeSilentScriptSource(),
            adapter: makeAdapter(launcher)
        )

        service.send(.playPause)

        #expect(service.controlIssue == "No active player is available.")
        #expect(launcher.commandArguments.isEmpty)
    }

    private func makeAdapter(_ launcher: FakeAdapterLauncher) -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(
            launcher: launcher,
            resolveApplication: { identifier, _ in
                MediaApplication(name: "Test Player", bundleIdentifier: identifier)
            }
        )
    }

    private func makeSilentScriptSource() -> AppleScriptMediaSource {
        AppleScriptMediaSource(
            executor: FakeAppleScriptExecutor(results: []),
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { [] }
        )
    }

    private func makeScriptSource(executor: FakeAppleScriptExecutor) -> AppleScriptMediaSource {
        AppleScriptMediaSource(
            executor: executor,
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { ["com.spotify.client"] }
        )
    }
}

@MainActor
@Suite("Scripted media failures")
struct ScriptedMediaFailureTests {
    @Test("Automation denial becomes an actionable state without a crash")
    func reportsAutomationDenial() async throws {
        let source = AppleScriptMediaSource(
            executor: FakeAppleScriptExecutor(results: [.denied]),
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { ["com.spotify.client"] }
        )
        let service = MediaService(appleScript: source, adapter: nil)

        service.startScriptedPlayers()
        try await settleMediaTasks()

        #expect(source.automationDenied)
        #expect(service.nowPlaying == nil)
        #expect(service.unavailableReason?.contains("Automation") == true)
        service.stop()
    }

    @Test("A timed-out scripted control reports a bounded diagnostic")
    func reportsControlTimeout() async throws {
        let executor = FakeAppleScriptExecutor(results: [
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
            .timedOut,
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
        ])
        let source = AppleScriptMediaSource(
            executor: executor,
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { ["com.spotify.client"] }
        )
        let recorder = MediaCallbackRecorder()
        source.onDiagnostic = { recorder.diagnostics.append($0) }

        source.start()
        try await settleMediaTasks()
        source.send(.playPause)
        try await settleMediaTasks()

        #expect(source.controlIssue == "The player did not respond.")
        #expect(recorder.diagnostics.last?.code == "control-timeout")
        source.stop()
    }

    @Test("A scripted control failure expires after its bounded display window")
    func expiresScriptedControlFailure() async throws {
        let sleeps = TestSleepRecorder()
        let executor = FakeAppleScriptExecutor(results: [
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
            .timedOut,
            .success(["playing", "Nightcall", "Kavinsky", "OutRun"]),
        ])
        let source = AppleScriptMediaSource(
            executor: executor,
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { ["com.spotify.client"] },
            controlIssueSleep: { duration in await sleeps.sleep(for: duration) }
        )

        source.start()
        try await settleMediaTasks()
        source.send(.playPause)
        try await settleMediaTasks()

        #expect(await sleeps.durations() == [.seconds(5)])
        #expect(source.controlIssue == nil)
        source.stop()
    }
}
