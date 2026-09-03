import Foundation

public actor FixtureUsageProviderAdapter: UsageProviderAdapter {
    public nonisolated let provider: ProviderID

    private var results: [Result<UsageSnapshot, ProviderError>]
    private let delay: Duration
    private var invocationCount = 0

    public init(
        provider: ProviderID,
        results: [Result<UsageSnapshot, ProviderError>],
        delay: Duration = .zero
    ) {
        self.provider = provider
        self.results = results
        self.delay = delay
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        invocationCount += 1
        guard !results.isEmpty else {
            throw ProviderError.adapterUnavailable(provider: provider)
        }
        let result = results.removeFirst()
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }

    public func fetchCount() -> Int {
        invocationCount
    }
}

public struct FixtureSessionEventSource: SessionEventSource {
    public let provider: ProviderID
    private let events: [SessionEvent]

    public init(provider: ProviderID, events: [SessionEvent]) {
        self.provider = provider
        self.events = events
    }

    public func makeEventStream() -> AsyncThrowingStream<SessionEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

public actor FixtureApprovalResponder: ApprovalResponder {
    public struct Response: Equatable, Sendable {
        public let requestID: String
        public let decision: ApprovalDecision

        public init(requestID: String, decision: ApprovalDecision) {
            self.requestID = requestID
            self.decision = decision
        }
    }

    public nonisolated let provider: ProviderID
    private let error: ProviderError?
    private var recordedResponses: [Response] = []

    public init(provider: ProviderID, error: ProviderError? = nil) {
        self.provider = provider
        self.error = error
    }

    public func respond(to request: ApprovalRequest, decision: ApprovalDecision) async throws {
        if let error {
            throw error
        }
        recordedResponses.append(Response(requestID: request.id, decision: decision))
    }

    public func responses() -> [Response] {
        recordedResponses
    }
}
