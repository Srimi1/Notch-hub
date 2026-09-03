import Foundation

public struct QuotaWindow: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowDurationMinutes: Int?

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowDurationMinutes: Int? = nil
    ) throws {
        self.id = try ExternalMetadataSanitizer.identifier(id, field: "quota window identifier")
        self.label = try ExternalMetadataSanitizer.displayText(label, field: "quota window label", limit: 80)

        guard usedPercent.isFinite, (0 ... 100).contains(usedPercent) else {
            throw ProviderError.invalidPayload(provider: nil, field: "quota usage percentage")
        }
        self.usedPercent = usedPercent

        if let windowDurationMinutes {
            guard (1 ... 5_256_000).contains(windowDurationMinutes) else {
                throw ProviderError.invalidPayload(provider: nil, field: "quota window duration")
            }
        }
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, resetsAt, windowDurationMinutes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            label: values.decode(String.self, forKey: .label),
            usedPercent: values.decode(Double.self, forKey: .usedPercent),
            resetsAt: values.decodeIfPresent(Date.self, forKey: .resetsAt),
            windowDurationMinutes: values.decodeIfPresent(Int.self, forKey: .windowDurationMinutes)
        )
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public let provider: ProviderID
    public let windows: [QuotaWindow]
    public let capturedAt: Date
    public let planName: String?
    public let creditsRemaining: Double?

    public init(
        provider: ProviderID,
        windows: [QuotaWindow],
        capturedAt: Date,
        planName: String? = nil,
        creditsRemaining: Double? = nil
    ) throws {
        guard !windows.isEmpty else {
            throw ProviderError.invalidPayload(provider: provider, field: "quota windows")
        }
        guard Set(windows.map(\.id)).count == windows.count else {
            throw ProviderError.invalidPayload(provider: provider, field: "quota window identifiers")
        }
        if let creditsRemaining, !creditsRemaining.isFinite || creditsRemaining < 0 {
            throw ProviderError.invalidPayload(provider: provider, field: "remaining credits")
        }

        self.provider = provider
        self.windows = windows
        self.capturedAt = capturedAt
        self.planName = try planName.map {
            try ExternalMetadataSanitizer.displayText($0, field: "plan name", limit: 64)
        }
        self.creditsRemaining = creditsRemaining
    }

    public var highestUsedPercent: Double {
        windows.map(\.usedPercent).max() ?? 0
    }

    public func isStale(at date: Date, after interval: TimeInterval) -> Bool {
        date.timeIntervalSince(capturedAt) >= max(interval, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, windows, capturedAt, planName, creditsRemaining
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: values.decode(ProviderID.self, forKey: .provider),
            windows: values.decode([QuotaWindow].self, forKey: .windows),
            capturedAt: values.decode(Date.self, forKey: .capturedAt),
            planName: values.decodeIfPresent(String.self, forKey: .planName),
            creditsRemaining: values.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        )
    }
}

public struct AgentSession: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case running
        case waitingForApproval
        case finished
        case failed
        case interrupted

        public var isActive: Bool {
            self == .running || self == .waitingForApproval
        }
    }

    public let id: String
    public let provider: ProviderID
    public let projectName: String?
    public let status: Status
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        provider: ProviderID,
        projectName: String?,
        status: Status,
        startedAt: Date,
        updatedAt: Date
    ) throws {
        guard updatedAt >= startedAt else {
            throw ProviderError.invalidPayload(provider: provider, field: "session timestamps")
        }

        self.id = try ExternalMetadataSanitizer.identifier(id, field: "session identifier")
        self.provider = provider
        self.projectName = ExternalMetadataSanitizer.projectName(projectName)
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, projectName, status, startedAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            provider: values.decode(ProviderID.self, forKey: .provider),
            projectName: values.decodeIfPresent(String.self, forKey: .projectName),
            status: values.decode(Status.self, forKey: .status),
            startedAt: values.decode(Date.self, forKey: .startedAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public enum ApprovalActionCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case command
    case fileChange
    case network
    case tool
    case unknown
}

public enum ApprovalRisk: Int, CaseIterable, Codable, Comparable, Hashable, Sendable {
    case low
    case moderate
    case high
    case critical

    public static func < (lhs: ApprovalRisk, rhs: ApprovalRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ApprovalDecision: String, Codable, Hashable, Sendable {
    case allowOnce
    case deny
}

public struct ApprovalRequest: Codable, Hashable, Identifiable, Sendable {
    public static let maximumLifetime: TimeInterval = 120

    public let id: String
    public let provider: ProviderID
    public let sessionID: String
    public let projectName: String?
    public let actionCategory: ApprovalActionCategory
    public let preview: String
    public let risk: ApprovalRisk
    public let receivedAt: Date
    public let expiresAt: Date

    public init(
        id: String,
        provider: ProviderID,
        sessionID: String,
        projectName: String?,
        actionCategory: ApprovalActionCategory,
        rawPreview: String?,
        risk: ApprovalRisk,
        receivedAt: Date,
        expiresAt: Date
    ) throws {
        let lifetime = expiresAt.timeIntervalSince(receivedAt)
        guard lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw ProviderError.invalidPayload(provider: provider, field: "approval expiry")
        }

        self.id = try ExternalMetadataSanitizer.identifier(id, field: "approval identifier")
        self.provider = provider
        self.sessionID = try ExternalMetadataSanitizer.identifier(sessionID, field: "session identifier")
        self.projectName = ExternalMetadataSanitizer.projectName(projectName)
        self.actionCategory = actionCategory
        self.preview = ExternalMetadataSanitizer.actionPreview(rawPreview, category: actionCategory)
        self.risk = actionCategory == .unknown ? .critical : risk
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionID, projectName, actionCategory, preview, risk, receivedAt, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            provider: values.decode(ProviderID.self, forKey: .provider),
            sessionID: values.decode(String.self, forKey: .sessionID),
            projectName: values.decodeIfPresent(String.self, forKey: .projectName),
            actionCategory: values.decode(ApprovalActionCategory.self, forKey: .actionCategory),
            rawPreview: values.decodeIfPresent(String.self, forKey: .preview),
            risk: values.decode(ApprovalRisk.self, forKey: .risk),
            receivedAt: values.decode(Date.self, forKey: .receivedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt)
        )
    }
}

public enum ProviderConnectionState: Codable, Hashable, Sendable {
    case notDetected
    case detected
    case connecting
    case connected(lastRefresh: Date)
    case signedOut
    case stale(lastSuccessfulRefresh: Date, reason: ProviderError?)
    case failed(ProviderError)
}

public enum SessionEvent: Codable, Hashable, Sendable {
    case upserted(AgentSession)
    case removed(provider: ProviderID, sessionID: String)
}
