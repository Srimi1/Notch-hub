import Foundation

public enum NotificationUsageThreshold: Int, CaseIterable, Hashable, Sendable {
    case warning = 80
    case exhausted = 100
}

public enum NotificationConnectionState: Hashable, Sendable {
    case connecting
    case connected
    case disconnected
    case failed

    var isAvailable: Bool {
        self == .connecting || self == .connected
    }

    var isDisconnected: Bool {
        self == .disconnected || self == .failed
    }
}

public struct NotificationQuotaObservation: Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = String(id.prefix(128))
        self.label = String(label.prefix(80))
        self.usedPercent = usedPercent.isFinite ? min(max(usedPercent, 0), 100) : 0
        self.resetsAt = resetsAt
    }

    func cycleKey(provider: ProviderID) -> String {
        let resetValue = resetsAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "open"
        return "\(provider.rawValue):\(id):\(resetValue)"
    }
}

public struct NotificationProviderObservation: Hashable, Identifiable, Sendable {
    public let id: ProviderID
    public let connection: NotificationConnectionState
    public let quotas: [NotificationQuotaObservation]

    public init(
        id: ProviderID,
        connection: NotificationConnectionState,
        quotas: [NotificationQuotaObservation]
    ) {
        self.id = id
        self.connection = connection
        self.quotas = quotas
    }
}

public enum NotificationSessionStatus: Hashable, Sendable {
    case active
    case completed
    case failed
}

public struct NotificationSessionObservation: Hashable, Identifiable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let projectName: String
    public let status: NotificationSessionStatus

    public init(
        id: String,
        provider: ProviderID,
        projectName: String,
        status: NotificationSessionStatus
    ) {
        self.id = String(id.prefix(128))
        self.provider = provider
        self.projectName = String(projectName.prefix(80))
        self.status = status
    }

    var stateKey: String {
        "\(provider.rawValue):\(id)"
    }
}

public struct NotificationApprovalObservation: Hashable, Identifiable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let projectName: String

    public init(id: String, provider: ProviderID, projectName: String) {
        self.id = String(id.prefix(128))
        self.provider = provider
        self.projectName = String(projectName.prefix(80))
    }

    var stateKey: String {
        "\(provider.rawValue):\(id)"
    }
}

public struct SmartQuietObservation: Hashable, Sendable {
    public let providers: [NotificationProviderObservation]
    public let sessions: [NotificationSessionObservation]
    public let approvals: [NotificationApprovalObservation]

    public init(
        providers: [NotificationProviderObservation],
        sessions: [NotificationSessionObservation],
        approvals: [NotificationApprovalObservation]
    ) {
        self.providers = providers
        self.sessions = sessions
        self.approvals = approvals
    }

    public static let empty = SmartQuietObservation(providers: [], sessions: [], approvals: [])
}

public enum SmartQuietNotificationKind: Hashable, Sendable {
    case approval
    case sessionCompleted
    case sessionFailed
    case providerDisconnected
    case usageThreshold(NotificationUsageThreshold)
}

public struct SmartQuietNotification: Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: SmartQuietNotificationKind
    public let title: String
    public let body: String

    public init(id: String, kind: SmartQuietNotificationKind, title: String, body: String) {
        self.id = String(id.prefix(256))
        self.kind = kind
        self.title = String(title.prefix(80))
        self.body = String(body.prefix(240))
    }
}

public struct SmartQuietPolicyState: Equatable, Sendable {
    var previousObservation: SmartQuietObservation?
    var seenApprovalKeys: [String]
    var seenTerminalSessionKeys: [String]
    var notifiedThresholds: [String: Set<NotificationUsageThreshold>]

    public init() {
        self.previousObservation = nil
        self.seenApprovalKeys = []
        self.seenTerminalSessionKeys = []
        self.notifiedThresholds = [:]
    }
}

public struct SmartQuietEvaluation: Equatable, Sendable {
    public let state: SmartQuietPolicyState
    public let notifications: [SmartQuietNotification]

    public init(state: SmartQuietPolicyState, notifications: [SmartQuietNotification]) {
        self.state = state
        self.notifications = notifications
    }
}
