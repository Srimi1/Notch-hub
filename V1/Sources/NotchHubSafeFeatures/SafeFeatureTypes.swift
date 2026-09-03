import Foundation

/// The complete Store-safe capability surface. This target deliberately has no
/// dependency on the direct edition's provider, hook, or process infrastructure.
public enum SafeFeature: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case clipboard
    case focus

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .clipboard: "Clipboard"
        case .focus: "Focus"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .clipboard: "clipboard"
        case .focus: "timer"
        }
    }
}

public enum SafeNotchTier: Sendable, Equatable {
    case compact
    case detail
}

public struct SafeNotchPanelMetrics: Sendable, Equatable {
    public let width: CGFloat
    public let height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
}
