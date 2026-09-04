import Foundation

@MainActor
public final class MediaRuntimeController {
    public typealias DiagnosticHandler = @MainActor @Sendable (MediaDiagnostic) -> Void

    private let model: MediaPresentationModel
    private let service: MediaService
    private let diagnosticHandler: DiagnosticHandler
    private var isRunning = false

    public convenience init(
        model: MediaPresentationModel,
        diagnosticHandler: @escaping DiagnosticHandler = { _ in }
    ) {
        self.init(model: model, service: MediaService(), diagnosticHandler: diagnosticHandler)
    }

    init(
        model: MediaPresentationModel,
        service: MediaService,
        diagnosticHandler: @escaping DiagnosticHandler
    ) {
        self.model = model
        self.service = service
        self.diagnosticHandler = diagnosticHandler
        installHandlers()
        publish()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        installHandlers()
        service.startSystemPlayback()
        publish()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        service.stop()
        model.configure(transport: nil, interaction: nil)
        publish()
    }

    private func installHandlers() {
        service.onDiagnostic = { [weak self] diagnostic in
            self?.diagnosticHandler(diagnostic)
        }
        service.onChange = { [weak self] in self?.publish() }
        model.configure(
            transport: { [weak self] command in self?.perform(command) },
            interaction: { [weak self] in self?.enableInteractiveSources() }
        )
    }

    private func enableInteractiveSources() {
        guard isRunning else { return }
        service.startScriptedPlayers()
        publish()
    }

    private func perform(_ command: MediaTransportCommand) {
        guard isRunning else {
            model.applyControlIssue("Playback controls are unavailable.")
            return
        }
        service.send(command)
        publish()
    }

    private func publish() {
        model.apply(
            nowPlaying: service.nowPlaying,
            unavailableReason: service.unavailableReason,
            emptyHint: service.emptyHint,
            controlIssue: service.controlIssue
        )
    }
}
