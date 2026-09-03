import Foundation
import NotchHubSafeFeatures
import Observation

/// Main-actor UI state. Provider actors publish sanitized presentation values
/// into this model; the model never owns a CLI, descriptor, or credential.
@MainActor
@Observable
public final class AppPresentationModel {
    public typealias ApprovalHandler = @MainActor @Sendable (
        String,
        ApprovalDecision
    ) async throws -> Void
    public typealias SessionBridgeHandler = @MainActor @Sendable (
        SessionBridgeAction
    ) async throws -> SessionBridgeConnectionPresentation

    public let edition: ApplicationEdition
    public let safeFeatures: SafeFeatureWorkspace
    public private(set) var tier: NotchPresentationTier
    public private(set) var selectedCapability: AppCapability
    public private(set) var providers: [ProviderCardPresentation]
    public private(set) var sessions: [AgentSessionPresentation]
    public private(set) var pendingApproval: ApprovalCardPresentation?
    public private(set) var approvalSubmission: ApprovalSubmissionState
    public private(set) var sessionBridgeConnection: SessionBridgeConnectionPresentation
    public private(set) var sessionBridgeSubmissionInProgress: Bool

    @ObservationIgnored private var approvalHandler: ApprovalHandler?
    @ObservationIgnored private var sessionBridgeHandler: SessionBridgeHandler?
    @ObservationIgnored private var layoutChangeHandler: (@MainActor () -> Void)?

    public init(
        edition: ApplicationEdition,
        approvalHandler: ApprovalHandler? = nil,
        safeFeatures: SafeFeatureWorkspace? = nil
    ) {
        self.edition = edition
        self.safeFeatures = safeFeatures ?? SafeFeatureWorkspace()
        self.tier = .compact
        self.selectedCapability = edition.defaultCapability
        self.providers = edition == .direct ? Self.disconnectedProviders : []
        self.sessions = []
        self.pendingApproval = nil
        self.approvalSubmission = .idle
        self.sessionBridgeConnection = edition == .direct ? .checking : .disconnected
        self.sessionBridgeSubmissionInProgress = false
        self.approvalHandler = approvalHandler
    }

    public var highestUtilization: Double? {
        providers.compactMap(\.highestUtilization).max()
    }

    public var hasAttention: Bool {
        pendingApproval != nil || providers.contains { $0.connection.requiresAttention }
    }

    public var activeSessionCount: Int {
        sessions.count { $0.status == .running || $0.status == .waitingForApproval }
    }

    public var panelMetrics: NotchPanelMetrics {
        switch tier {
        case .compact:
            .init(
                width: CompactNotchTheme.compactWidth,
                height: CompactNotchTheme.compactHeight
            )
        case .detail:
            .init(
                width: CompactNotchTheme.expandedWidth,
                height: CompactNotchTheme.expandedHeight
            )
        }
    }

    public func setLayoutChangeHandler(_ handler: (@MainActor () -> Void)?) {
        layoutChangeHandler = handler
    }

    public func setApprovalHandler(_ handler: ApprovalHandler?) {
        approvalHandler = handler
    }

    public func setSessionBridgeHandler(_ handler: SessionBridgeHandler?) {
        sessionBridgeHandler = handler
    }

    public func setSessionBridgeConnection(_ connection: SessionBridgeConnectionPresentation) {
        guard edition == .direct else { return }
        sessionBridgeConnection = connection
    }

    public func showCompact() {
        guard tier != .compact else { return }
        tier = .compact
        layoutChangeHandler?()
    }

    public func showDetail() {
        guard tier != .detail else { return }
        tier = .detail
        layoutChangeHandler?()
    }

    public func select(_ capability: AppCapability) {
        guard edition.capabilities.contains(capability) else { return }
        selectedCapability = capability
        showDetail()
    }

    public func replaceProviders(_ values: [ProviderCardPresentation]) {
        guard edition == .direct else { return }
        providers = values.sorted(by: Self.providerSort)
        if tier == .compact {
            layoutChangeHandler?()
        }
    }

    public func apply(
        provider: ProviderID,
        snapshot: UsageSnapshot?,
        connection: ProviderConnectionState
    ) {
        guard edition == .direct else { return }
        let value = ProviderCardPresentation(
            provider: provider,
            snapshot: snapshot,
            connection: connection
        )
        providers.removeAll { $0.id == provider.rawValue }
        providers.append(value)
        providers.sort(by: Self.providerSort)
        if tier == .compact {
            layoutChangeHandler?()
        }
    }

    public func replaceSessions(_ values: [AgentSessionPresentation]) {
        guard edition == .direct else { return }
        sessions = values.sorted { $0.updatedAt > $1.updatedAt }
        if tier == .compact {
            layoutChangeHandler?()
        }
    }

    public func replaceSessions(_ values: [AgentSession]) {
        replaceSessions(values.map(AgentSessionPresentation.init))
    }

    public func presentApproval(_ approval: ApprovalCardPresentation) {
        guard edition == .direct else { return }
        pendingApproval = approval
        approvalSubmission = .idle
        selectedCapability = .agents
        tier = .detail
        layoutChangeHandler?()
    }

    public func presentApproval(_ approval: ApprovalRequest) {
        presentApproval(.init(approval))
    }

    public func dismissApproval() {
        pendingApproval = nil
        approvalSubmission = .idle
        layoutChangeHandler?()
    }

    public func submitApproval(_ decision: ApprovalDecision) async {
        guard let pendingApproval, approvalSubmission != .submitting else { return }
        guard pendingApproval.expiresAt > .now else {
            dismissApproval()
            return
        }
        guard let approvalHandler else {
            approvalSubmission = .failed("No secure approval connection is available.")
            return
        }
        approvalSubmission = .submitting
        do {
            try await approvalHandler(pendingApproval.id, decision)
            dismissApproval()
        } catch {
            approvalSubmission = .failed("The provider kept its native approval prompt.")
        }
    }

    public func performSessionBridgeAction() async {
        guard edition == .direct,
              !sessionBridgeSubmissionInProgress,
              let action = sessionBridgeConnection.action,
              let sessionBridgeHandler
        else { return }
        sessionBridgeSubmissionInProgress = true
        defer { sessionBridgeSubmissionInProgress = false }
        do {
            sessionBridgeConnection = try await sessionBridgeHandler(action)
        } catch {
            sessionBridgeConnection = .failed("Session setup failed safely; provider prompts remain active.")
        }
    }

    private static let disconnectedProviders = ProviderID.allCases.map {
        ProviderCardPresentation(provider: $0, snapshot: nil, connection: .notDetected)
    }

    private static func providerSort(
        _ left: ProviderCardPresentation,
        _ right: ProviderCardPresentation
    ) -> Bool {
        providerRank(left.id) < providerRank(right.id)
    }

    private static func providerRank(_ identifier: String) -> Int {
        ProviderID.allCases.firstIndex { $0.rawValue == identifier } ?? ProviderID.allCases.count
    }
}

#if DEBUG
    /// Explicit preview/test-only data. Production launch paths never call this.
    @MainActor
    public enum PresentationPreviewFactory {
        public static func direct(now: Date = .now) -> AppPresentationModel {
            let model = AppPresentationModel(edition: .direct)
            model.replaceProviders([
                previewProvider(.init(
                    id: "codex",
                    name: "Codex",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    windowID: "five-hour",
                    windowLabel: "5 hour",
                    usedPercent: 64,
                    resetsAt: now.addingTimeInterval(3000),
                    capturedAt: now
                )),
                previewProvider(.init(
                    id: "claude",
                    name: "Claude",
                    symbol: "brain.head.profile",
                    windowID: "weekly",
                    windowLabel: "Weekly",
                    usedPercent: 82,
                    resetsAt: now.addingTimeInterval(86400),
                    capturedAt: now
                )),
            ])
            model.replaceSessions([
                .init(
                    id: "preview-session",
                    providerName: "Codex",
                    projectName: "Example project",
                    status: .running,
                    updatedAt: now
                ),
            ])
            return model
        }

        private static func previewProvider(_ value: PreviewProvider) -> ProviderCardPresentation {
            ProviderCardPresentation(
                id: value.id,
                name: value.name,
                symbol: value.symbol,
                connection: .connected,
                quotaWindows: [
                    .init(
                        id: value.windowID,
                        label: value.windowLabel,
                        usedPercent: value.usedPercent,
                        resetsAt: value.resetsAt
                    ),
                ],
                capturedAt: value.capturedAt
            )
        }

        private struct PreviewProvider {
            let id: String
            let name: String
            let symbol: String
            let windowID: String
            let windowLabel: String
            let usedPercent: Double
            let resetsAt: Date
            let capturedAt: Date
        }
    }
#endif
