import Foundation

public extension SmartQuietObservation {
    @MainActor
    init(presentationModel model: AppPresentationModel) {
        self.init(
            providers: model.providers.compactMap(NotificationProviderObservation.init),
            sessions: model.sessions.compactMap(NotificationSessionObservation.init),
            approvals: model.pendingApproval.flatMap(NotificationApprovalObservation.init).map { [$0] } ?? []
        )
    }
}

private extension NotificationProviderObservation {
    init?(_ provider: ProviderCardPresentation) {
        guard let providerID = ProviderID(rawValue: provider.id) else { return nil }
        self.init(
            id: providerID,
            connection: .init(provider.connection),
            quotas: provider.quotaWindows.map {
                NotificationQuotaObservation(
                    id: $0.id,
                    label: $0.label,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        )
    }
}

private extension NotificationConnectionState {
    init(_ connection: ProviderConnectionPresentation) {
        switch connection {
        case .discovering: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .unavailable, .failed: self = .failed
        }
    }
}

private extension NotificationSessionObservation {
    init?(_ session: AgentSessionPresentation) {
        guard let provider = ProviderID.allCases.first(where: { $0.displayName == session.providerName }) else {
            return nil
        }
        self.init(
            id: session.id,
            provider: provider,
            projectName: session.projectName,
            status: .init(session.status)
        )
    }
}

private extension NotificationSessionStatus {
    init(_ status: SessionStatusPresentation) {
        switch status {
        case .running, .waitingForApproval: self = .active
        case .finished: self = .completed
        case .failed: self = .failed
        }
    }
}

private extension NotificationApprovalObservation {
    init?(_ approval: ApprovalCardPresentation) {
        guard let provider = ProviderID.allCases.first(where: { $0.displayName == approval.providerName }) else {
            return nil
        }
        self.init(id: approval.id, provider: provider, projectName: approval.projectName)
    }
}
