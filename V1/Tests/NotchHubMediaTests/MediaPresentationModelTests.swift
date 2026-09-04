import Testing
@testable import NotchHubMedia

@MainActor
@Suite("Media presentation model")
struct MediaPresentationModelTests {
    @Test("Transport and interaction handlers receive explicit user actions")
    func routesPresentationActions() {
        let model = MediaPresentationModel()
        let recorder = MediaCallbackRecorder()
        model.configure(
            transport: { recorder.commands.append($0) },
            interaction: { recorder.interactions += 1 }
        )
        model.apply(
            nowPlaying: mediaTrack("Nightcall", playing: true),
            unavailableReason: nil,
            emptyHint: "Play something",
            controlIssue: nil
        )

        model.send(.previous)
        model.send(.playPause)
        model.send(.next)
        model.requestInteractiveAccess()

        #expect(recorder.commands == [.previous, .playPause, .next])
        #expect(recorder.interactions == 1)
        #expect(model.isPlaying)
        #expect(model.hasActivity)
    }

    @Test("No track means transport is a safe no-op")
    func ignoresTransportWithoutTrack() {
        let model = MediaPresentationModel()
        let recorder = MediaCallbackRecorder()
        model.configure(transport: { recorder.commands.append($0) }, interaction: nil)

        model.send(.next)

        #expect(recorder.commands.isEmpty)
        #expect(model.lastControlIssue == nil)
    }

    @Test("A missing transport handler produces a visible failure")
    func reportsUnavailableTransport() {
        let model = MediaPresentationModel()
        model.apply(
            nowPlaying: mediaTrack("Nightcall", playing: false),
            unavailableReason: nil,
            emptyHint: "Play something",
            controlIssue: nil
        )

        model.send(.next)

        #expect(model.lastControlIssue == "Playback controls are unavailable.")
    }

    @Test("Activity callbacks fire only when playback presentation changes")
    func publishesActivityChanges() {
        let model = MediaPresentationModel()
        let recorder = MediaCallbackRecorder()
        let track = mediaTrack("Nightcall", playing: true)
        model.setActivityChangeHandler { recorder.changes += 1 }

        model.apply(nowPlaying: track, unavailableReason: nil, emptyHint: "One", controlIssue: nil)
        model.apply(nowPlaying: track, unavailableReason: "Issue", emptyHint: "Two", controlIssue: "Issue")
        model.apply(nowPlaying: nil, unavailableReason: nil, emptyHint: "Three", controlIssue: nil)

        #expect(recorder.changes == 2)
        #expect(model.nowPlaying == nil)
        #expect(model.emptyHint == "Three")
    }
}

@MainActor
@Suite("Media runtime controller")
struct MediaRuntimeControllerTests {
    @Test("System playback starts first and scripted players require interaction")
    func preservesPermissionBoundary() async throws {
        let launcher = FakeAdapterLauncher()
        let adapter = makeAdapter(launcher)
        let script = makeScriptSource()
        let service = MediaService(appleScript: script, adapter: adapter)
        let model = MediaPresentationModel()
        let controller = MediaRuntimeController(model: model, service: service) { _ in }

        controller.start()
        try await settleMediaTasks()
        #expect(launcher.streamArguments.count == 1)
        #expect(!script.isPolling)

        model.requestInteractiveAccess()
        try await settleMediaTasks()
        #expect(script.isPolling)
        controller.stop()
    }

    @Test("A stopped runtime can restart with its handlers restored")
    func restartsCleanly() async throws {
        let launcher = FakeAdapterLauncher()
        let script = makeScriptSource()
        let service = MediaService(appleScript: script, adapter: makeAdapter(launcher))
        let model = MediaPresentationModel()
        let controller = MediaRuntimeController(model: model, service: service) { _ in }

        controller.start()
        controller.stop()
        controller.start()
        model.requestInteractiveAccess()
        try await settleMediaTasks()

        #expect(launcher.streamArguments.count == 2)
        #expect(script.isPolling)
        controller.stop()
    }

    @Test("Runtime diagnostics are routed to the owning application")
    func routesDiagnostics() async throws {
        let launcher = FakeAdapterLauncher()
        let recorder = MediaCallbackRecorder()
        let service = MediaService(
            appleScript: makeScriptSource(),
            adapter: makeAdapter(launcher)
        )
        let controller = MediaRuntimeController(
            model: MediaPresentationModel(),
            service: service,
            diagnosticHandler: { recorder.diagnostics.append($0) }
        )

        controller.start()
        try await settleMediaTasks()
        launcher.emitStream(.line("not-json"))
        try await settleMediaTasks()

        #expect(recorder.diagnostics.last?.code == "adapter-payload-rejected")
        controller.stop()
    }

    private func makeAdapter(_ launcher: FakeAdapterLauncher) -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(
            launcher: launcher,
            resolveApplication: { identifier, _ in
                MediaApplication(name: "Test Player", bundleIdentifier: identifier)
            }
        )
    }

    private func makeScriptSource() -> AppleScriptMediaSource {
        AppleScriptMediaSource(
            executor: FakeAppleScriptExecutor(results: []),
            pollInterval: .seconds(60),
            runningBundleIdentifiers: { [] }
        )
    }
}
