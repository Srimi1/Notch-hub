import Foundation
import Testing
@testable import NotchHubMedia

@MainActor
@Suite("Media adapter lifecycle")
struct MediaAdapterLifecycleTests {
    @Test("Starting is idempotent and a validated snapshot updates once")
    func startsAndPublishesTrack() async throws {
        let launcher = FakeAdapterLauncher()
        let recorder = MediaCallbackRecorder()
        let source = makeSource(launcher)
        source.onChange = { recorder.changes += 1 }

        source.start()
        source.start()
        try await settleMediaTasks()
        launcher.emitStream(.line(mediaAdapterLine(title: "Nightcall", playing: true)))
        launcher.emitStream(.line(mediaAdapterLine(title: "Nightcall", playing: true)))
        try await settleMediaTasks()

        #expect(launcher.streamArguments == [MediaRemoteAdapterSource.streamArguments])
        #expect(source.nowPlaying?.title == "Nightcall")
        #expect(source.nowPlaying?.appName == "Test Player")
        #expect(source.nowPlaying?.isPlaying == true)
        #expect(recorder.changes == 1)
        source.stop()
    }

    @Test("Stopping terminates only the owned process and suppresses stale restarts")
    func stopsWithoutRestart() async throws {
        let launcher = FakeAdapterLauncher()
        let source = makeSource(launcher)

        source.start()
        try await settleMediaTasks()
        let handle = try #require(launcher.latestStreamHandle)
        source.stop()
        launcher.emitStream(.exited(status: 1))
        try await settleMediaTasks()

        #expect(handle.terminationCount == 1)
        #expect(launcher.streamArguments.count == 1)
        #expect(!source.isStreaming)
        #expect(!source.isUnavailable)
    }

    @Test("A crash restarts with bounded exponential backoff")
    func restartsAfterCrash() async throws {
        let launcher = FakeAdapterLauncher()
        let sleeps = TestSleepRecorder()
        let source = makeSource(launcher, sleeps: sleeps)

        source.start()
        try await settleMediaTasks()
        launcher.emitStream(.exited(status: 1))
        try await settleMediaTasks()
        launcher.emitStream(.exited(status: 1))
        try await settleMediaTasks()

        #expect(launcher.streamArguments.count == 3)
        #expect(await sleeps.durations() == [.seconds(1), .seconds(2)])
        #expect(!source.isUnavailable)
        source.stop()
    }

    @Test("Repeated failures stop at the fixed ceiling and surface a diagnostic")
    func givesUpAfterBoundedFailures() async throws {
        let launcher = FakeAdapterLauncher()
        let recorder = MediaCallbackRecorder()
        let source = makeSource(launcher)
        source.onDiagnostic = { recorder.diagnostics.append($0) }

        source.start()
        try await settleMediaTasks()
        for _ in 0 ..< MediaRemoteAdapterSource.maximumConsecutiveFailures {
            launcher.emitStream(.exited(status: 1))
            try await settleMediaTasks()
        }

        #expect(source.isUnavailable)
        #expect(source.nowPlaying == nil)
        #expect(launcher.streamArguments.count == MediaRemoteAdapterSource.maximumConsecutiveFailures)
        #expect(recorder.diagnostics.last?.code == "adapter-unavailable")
    }

    @Test("Launch failure follows the same bounded recovery path")
    func recoversFromLaunchFailure() async throws {
        let launcher = FakeAdapterLauncher()
        let sleeps = TestSleepRecorder()
        launcher.failNextStreamLaunches(1)
        let source = makeSource(launcher, sleeps: sleeps)

        source.start()
        try await settleMediaTasks()

        #expect(launcher.streamArguments.count == 2)
        #expect(await sleeps.durations() == [.seconds(1)])
        #expect(!source.isUnavailable)
        source.stop()
    }

    @Test("Failure math resets only after a stable run and caps delay")
    func calculatesBoundedBackoff() {
        let window = MediaRemoteAdapterSource.stabilityWindow

        #expect(MediaRemoteAdapterSource.failures(afterExitWithUptime: 1, previousFailures: 4) == 5)
        #expect(MediaRemoteAdapterSource.failures(afterExitWithUptime: window, previousFailures: 4) == 1)
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 0) == 0)
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 5) == 16)
        #expect(MediaRemoteAdapterSource.restartDelay(afterFailures: 50) == 30)
    }

    private func makeSource(
        _ launcher: FakeAdapterLauncher,
        sleeps: TestSleepRecorder = TestSleepRecorder()
    ) -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(
            launcher: launcher,
            resolveApplication: { identifier, _ in
                MediaApplication(name: "Test Player", bundleIdentifier: identifier)
            },
            restartSleep: { duration in await sleeps.sleep(for: duration) }
        )
    }
}

@MainActor
@Suite("Media adapter controls")
struct MediaAdapterControlTests {
    @Test("Transport uses only the fixed adapter command identifiers")
    func sendsFixedCommandIdentifiers() async throws {
        let launcher = FakeAdapterLauncher()
        let source = makeSource(launcher)

        source.send(.playPause)
        launcher.finishCommand(status: 0)
        try await settleMediaTasks()
        source.send(.next)
        launcher.finishCommand(status: 0)
        try await settleMediaTasks()
        source.send(.previous)
        launcher.finishCommand(status: 0)
        try await settleMediaTasks()

        #expect(launcher.commandArguments == [["send", "2"], ["send", "4"], ["send", "5"]])
    }

    @Test("Command launch and exit failures are visible but nonfatal")
    func surfacesCommandFailures() async throws {
        let launcher = FakeAdapterLauncher()
        let recorder = MediaCallbackRecorder()
        let source = makeSource(launcher)
        source.onDiagnostic = { recorder.diagnostics.append($0) }
        launcher.failNextCommandLaunches(1)

        source.send(.next)
        #expect(source.controlIssue == "Playback control could not start.")
        #expect(recorder.diagnostics.last?.code == "command-launch-failed")

        source.send(.next)
        launcher.finishCommand(status: 7)
        try await settleMediaTasks()
        #expect(source.controlIssue == "The player could not perform that control.")
        #expect(recorder.diagnostics.last?.code == "command-failed")
    }

    @Test("A failed control expires instead of becoming permanent")
    func expiresControlFailure() async throws {
        let launcher = FakeAdapterLauncher()
        let sleeps = TestSleepRecorder()
        let source = makeSource(launcher, controlIssueSleep: { duration in
            await sleeps.sleep(for: duration)
        })
        launcher.failNextCommandLaunches(1)

        source.send(.next)
        #expect(source.controlIssue == "Playback control could not start.")
        try await settleMediaTasks()

        #expect(await sleeps.durations() == [.seconds(5)])
        #expect(source.controlIssue == nil)
    }

    @Test("Rejected adapter output is diagnosed without becoming a track")
    func reportsRejectedOutput() async throws {
        let launcher = FakeAdapterLauncher()
        let recorder = MediaCallbackRecorder()
        let source = makeSource(launcher)
        source.onDiagnostic = { recorder.diagnostics.append($0) }

        source.start()
        try await settleMediaTasks()
        launcher.emitStream(.discardedOutput)
        launcher.emitStream(.line("malformed"))
        try await settleMediaTasks()

        #expect(source.nowPlaying == nil)
        #expect(recorder.diagnostics.map(\.code).contains("adapter-output-discarded"))
        #expect(recorder.diagnostics.map(\.code).contains("adapter-payload-rejected"))
        source.stop()
    }

    private func makeSource(
        _ launcher: FakeAdapterLauncher,
        controlIssueSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(
            launcher: launcher,
            resolveApplication: { identifier, _ in
                MediaApplication(name: "Test Player", bundleIdentifier: identifier)
            },
            controlIssueSleep: controlIssueSleep
        )
    }
}
