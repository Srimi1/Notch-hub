import Foundation

public struct BridgeAgentStateSnapshot: Sendable, Equatable {
    public let sessions: [AgentSession]
    public let pendingApproval: ApprovalRequest?

    public init(sessions: [AgentSession], pendingApproval: ApprovalRequest?) {
        self.sessions = sessions
        self.pendingApproval = pendingApproval
    }
}
