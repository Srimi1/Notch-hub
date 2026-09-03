import Foundation

public protocol UsageProviderAdapter: Sendable {
    var provider: ProviderID { get }
    func fetchUsage() async throws -> UsageSnapshot
}

public protocol SessionEventSource: Sendable {
    var provider: ProviderID { get }
    func makeEventStream() -> AsyncThrowingStream<SessionEvent, any Error>
}

public protocol ApprovalResponder: Sendable {
    var provider: ProviderID { get }
    func respond(to request: ApprovalRequest, decision: ApprovalDecision) async throws
}
