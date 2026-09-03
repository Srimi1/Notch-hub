import Observation

/// Long-lived, in-memory ownership for the three sandbox-compatible modules.
@MainActor
@Observable
public final class SafeFeatureWorkspace {
    public let dashboard: DashboardModel
    public let clipboard: ClipboardHistoryModel
    public let focus: FocusTimerModel

    public init(
        dashboard: DashboardModel? = nil,
        clipboard: ClipboardHistoryModel? = nil,
        focus: FocusTimerModel? = nil
    ) {
        self.dashboard = dashboard ?? DashboardModel()
        self.clipboard = clipboard ?? ClipboardHistoryModel()
        self.focus = focus ?? FocusTimerModel()
    }

    public func start() {
        dashboard.start()
        clipboard.start()
    }

    public func stop() {
        dashboard.stop()
        clipboard.stop()
        focus.stopScheduling()
    }
}
