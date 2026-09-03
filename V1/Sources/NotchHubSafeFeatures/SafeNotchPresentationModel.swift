import Observation

@MainActor
@Observable
public final class SafeNotchPresentationModel {
    public private(set) var tier: SafeNotchTier
    public private(set) var selectedFeature: SafeFeature
    public let workspace: SafeFeatureWorkspace

    @ObservationIgnored private var layoutChangeHandler: (@MainActor () -> Void)?

    public init(workspace: SafeFeatureWorkspace? = nil) {
        self.tier = .compact
        self.selectedFeature = .dashboard
        self.workspace = workspace ?? SafeFeatureWorkspace()
    }

    public var panelMetrics: SafeNotchPanelMetrics {
        switch tier {
        case .compact: .init(width: 440, height: 176)
        case .detail: .init(width: 680, height: 520)
        }
    }

    public func setLayoutChangeHandler(_ handler: (@MainActor () -> Void)?) {
        layoutChangeHandler = handler
    }

    public func showCompact() {
        setTier(.compact)
    }

    public func showDetail() {
        setTier(.detail)
    }

    public func select(_ feature: SafeFeature) {
        selectedFeature = feature
        setTier(.detail)
    }

    private func setTier(_ value: SafeNotchTier) {
        guard tier != value else { return }
        tier = value
        layoutChangeHandler?()
    }
}
