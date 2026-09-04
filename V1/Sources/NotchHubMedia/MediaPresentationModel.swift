import Observation

@MainActor
@Observable
public final class MediaPresentationModel {
    public private(set) var nowPlaying: MediaNowPlaying?
    public private(set) var unavailableReason: String?
    public private(set) var emptyHint: String
    public private(set) var lastControlIssue: String?

    @ObservationIgnored private var transportHandler: (@MainActor @Sendable (MediaTransportCommand) -> Void)?
    @ObservationIgnored private var interactionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var activityChangeHandler: (@MainActor @Sendable () -> Void)?

    public init() {
        self.nowPlaying = nil
        self.unavailableReason = nil
        self.emptyHint = "Play something — it shows up here."
        self.lastControlIssue = nil
    }

    public var isPlaying: Bool {
        nowPlaying?.isPlaying ?? false
    }

    public var hasActivity: Bool {
        nowPlaying != nil
    }

    public func send(_ command: MediaTransportCommand) {
        guard nowPlaying != nil else { return }
        guard let transportHandler else {
            applyControlIssue("Playback controls are unavailable.")
            return
        }
        transportHandler(command)
    }

    public func requestInteractiveAccess() {
        interactionHandler?()
    }

    public func setActivityChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        activityChangeHandler = handler
    }

    func configure(
        transport: (@MainActor @Sendable (MediaTransportCommand) -> Void)?,
        interaction: (@MainActor @Sendable () -> Void)?
    ) {
        transportHandler = transport
        interactionHandler = interaction
    }

    func apply(
        nowPlaying: MediaNowPlaying?,
        unavailableReason: String?,
        emptyHint: String,
        controlIssue: String?
    ) {
        let activityChanged = self.nowPlaying != nowPlaying
        self.nowPlaying = nowPlaying
        self.unavailableReason = unavailableReason
        self.emptyHint = emptyHint
        self.lastControlIssue = controlIssue
        if activityChanged { activityChangeHandler?() }
    }

    func applyControlIssue(_ issue: String?) {
        lastControlIssue = issue
    }
}
