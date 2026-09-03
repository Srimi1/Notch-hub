import Foundation

/// Features that can be surfaced by a NotchHub edition.
public enum AppCapability: String, CaseIterable, Identifiable, Sendable {
    case agents
    case dashboard
    case media
    case clipboard
    case focus

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .dashboard: "Dashboard"
        case .media: "Media"
        case .clipboard: "Clipboard"
        case .focus: "Focus"
        }
    }

    public var systemImage: String {
        switch self {
        case .agents: "sparkles"
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .media: "play.circle"
        case .clipboard: "clipboard"
        case .focus: "timer"
        }
    }
}

/// Distribution-specific feature policy. The Lite edition never advertises
/// provider, media-control, hook, or cleanup capabilities.
public enum ApplicationEdition: String, Sendable {
    case direct
    case lite

    public var displayName: String {
        switch self {
        case .direct: "NotchHub V1"
        case .lite: "NotchHub Lite"
        }
    }

    public var capabilities: [AppCapability] {
        switch self {
        case .direct: [.agents, .dashboard, .clipboard, .focus]
        case .lite: [.dashboard, .clipboard, .focus]
        }
    }

    public var defaultCapability: AppCapability {
        switch self {
        case .direct: .agents
        case .lite: .dashboard
        }
    }
}

public enum NotchPresentationTier: Sendable, Equatable {
    case compact
    case detail
}

public enum ProviderConnectionPresentation: Sendable, Equatable {
    case discovering
    case disconnected
    case connected
    case unavailable(String)
    case failed(String)

    public var label: String {
        switch self {
        case .discovering: "Discovering"
        case .disconnected: "Not connected"
        case .connected: "Connected"
        case let .unavailable(reason), let .failed(reason): reason
        }
    }

    public var requiresAttention: Bool {
        switch self {
        case .unavailable, .failed: true
        case .discovering, .disconnected, .connected: false
        }
    }

    public init(_ state: ProviderConnectionState) {
        switch state {
        case .notDetected: self = .disconnected
        case .detected, .connecting: self = .discovering
        case .connected: self = .connected
        case .signedOut: self = .unavailable("Sign in required")
        case .stale: self = .failed("Last update is stale")
        case let .failed(error): self = .failed(error.presentationLabel)
        }
    }
}

public struct QuotaWindowPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    public init(_ window: QuotaWindow) {
        self.init(
            id: window.id,
            label: window.label,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt
        )
    }
}

public struct ProviderCardPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let symbol: String
    public var connection: ProviderConnectionPresentation
    public var quotaWindows: [QuotaWindowPresentation]
    public var capturedAt: Date?

    public init(
        id: String,
        name: String,
        symbol: String,
        connection: ProviderConnectionPresentation,
        quotaWindows: [QuotaWindowPresentation] = [],
        capturedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.connection = connection
        self.quotaWindows = quotaWindows
        self.capturedAt = capturedAt
    }

    public init(
        provider: ProviderID,
        snapshot: UsageSnapshot?,
        connection: ProviderConnectionState
    ) {
        self.init(
            id: provider.rawValue,
            name: provider.displayName,
            symbol: provider.presentationSymbol,
            connection: .init(connection),
            quotaWindows: snapshot?.windows.map(QuotaWindowPresentation.init) ?? [],
            capturedAt: snapshot?.capturedAt
        )
    }

    public var highestUtilization: Double? {
        quotaWindows.map(\.usedPercent).max()
    }
}

public enum SessionStatusPresentation: String, Sendable, Equatable {
    case running
    case waitingForApproval
    case finished
    case failed

    public var label: String {
        switch self {
        case .running: "Running"
        case .waitingForApproval: "Needs approval"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    public init(_ status: AgentSession.Status) {
        switch status {
        case .running: self = .running
        case .waitingForApproval: self = .waitingForApproval
        case .finished: self = .finished
        case .failed, .interrupted: self = .failed
        }
    }
}

public struct AgentSessionPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let providerName: String
    public let projectName: String
    public let status: SessionStatusPresentation
    public let updatedAt: Date

    public init(
        id: String,
        providerName: String,
        projectName: String,
        status: SessionStatusPresentation,
        updatedAt: Date
    ) {
        self.id = id
        self.providerName = providerName
        self.projectName = Self.bounded(projectName, limit: 64)
        self.status = status
        self.updatedAt = updatedAt
    }

    public init(_ session: AgentSession) {
        self.init(
            id: session.id,
            providerName: session.provider.displayName,
            projectName: session.projectName ?? "Private project",
            status: .init(session.status),
            updatedAt: session.updatedAt
        )
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(limit))
    }
}

public enum ApprovalRiskPresentation: String, Sendable, Equatable {
    case low
    case elevated
    case high

    public var label: String {
        switch self {
        case .low: "Low risk"
        case .elevated: "Review carefully"
        case .high: "High risk"
        }
    }

    public init(_ risk: ApprovalRisk) {
        switch risk {
        case .low: self = .low
        case .moderate: self = .elevated
        case .high, .critical: self = .high
        }
    }
}

public struct ApprovalCardPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let providerName: String
    public let projectName: String
    public let actionCategory: String
    public let preview: String?
    public let risk: ApprovalRiskPresentation
    public let expiresAt: Date

    public init(
        id: String,
        providerName: String,
        projectName: String,
        actionCategory: String,
        preview: String?,
        risk: ApprovalRiskPresentation,
        expiresAt: Date
    ) {
        self.id = id
        self.providerName = Self.bounded(providerName, limit: 32)
        self.projectName = Self.bounded(projectName, limit: 64)
        self.actionCategory = Self.bounded(actionCategory, limit: 48)
        self.preview = preview.map { Self.bounded($0, limit: 240) }
        self.risk = risk
        self.expiresAt = expiresAt
    }

    public init(_ request: ApprovalRequest) {
        self.init(
            id: request.id,
            providerName: request.provider.displayName,
            projectName: request.projectName ?? "Private project",
            actionCategory: request.actionCategory.presentationLabel,
            preview: request.preview,
            risk: .init(request.risk),
            expiresAt: request.expiresAt
        )
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(limit))
    }
}

public enum ApprovalSubmissionState: Sendable, Equatable {
    case idle
    case submitting
    case failed(String)
}

public struct NotchPanelMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

private extension ProviderID {
    var presentationSymbol: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "brain.head.profile"
        }
    }
}

private extension ApprovalActionCategory {
    var presentationLabel: String {
        switch self {
        case .command: "Command"
        case .fileChange: "File change"
        case .network: "Network"
        case .tool: "Tool"
        case .unknown: "Unknown action"
        }
    }
}

private extension ProviderError {
    var presentationLabel: String {
        switch self {
        case .cliNotFound: "CLI not found"
        case .signedOut: "Sign in required"
        case .unsupportedVersion: "CLI update required"
        case .timeout: "Provider timed out"
        case .malformedResponse: "Unreadable provider response"
        case .offline: "Provider is offline"
        case .hookConflict: "Hook setup needs review"
        case .processFailed: "Provider process failed"
        case .cancelled: "Refresh cancelled"
        case .adapterUnavailable: "Usage is unavailable"
        case .approvalResponderUnavailable: "Approval connection unavailable"
        case .approvalNotFound: "Approval no longer available"
        case .approvalExpired: "Approval expired"
        case .approvalInProgress: "Approval already in progress"
        case .invalidPayload: "Invalid provider response"
        }
    }
}
