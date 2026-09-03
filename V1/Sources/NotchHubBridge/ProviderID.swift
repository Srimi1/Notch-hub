import Foundation

public enum ProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var id: String {
        rawValue
    }

    public var executableName: String {
        rawValue
    }
}
