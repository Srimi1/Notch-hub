import Foundation
import Testing
@testable import NotchHubCore

@Suite("Smart-quiet notifications")
struct NotificationPolicyTests {
    @Test("Normal usage progress stays quiet")
    func normalProgressIsSuppressed() {
        var state = SmartQuietPolicyState()
        state = evaluate(state, usage: 10).state
        let result = evaluate(state, usage: 62)

        #expect(result.notifications.isEmpty)
    }

    @Test("Approval is emitted once even if it remains pending")
    func approvalIsDeduplicated() {
        let approval = NotificationApprovalObservation(
            id: "approval",
            provider: .codex,
            projectName: "NotchHub"
        )
        var state = SmartQuietPolicyState()
        let first = SmartQuietNotificationPolicy.evaluate(
            state: state,
            observation: .init(providers: [], sessions: [], approvals: [approval])
        )
        state = first.state
        let duplicate = SmartQuietNotificationPolicy.evaluate(
            state: state,
            observation: .init(providers: [], sessions: [], approvals: [approval])
        )

        #expect(first.notifications.map(\.kind) == [.approval])
        #expect(duplicate.notifications.isEmpty)
    }

    @Test("Only active-to-terminal session transitions notify")
    func terminalSessionTransitionsNotify() {
        let active = session(id: "completed", status: .active)
        let initialTerminal = session(id: "historical", status: .completed)
        var state = SmartQuietNotificationPolicy.evaluate(
            state: .init(),
            observation: observation(sessions: [active, initialTerminal])
        ).state
        let completion = SmartQuietNotificationPolicy.evaluate(
            state: state,
            observation: observation(sessions: [session(id: "completed", status: .completed)])
        )
        state = completion.state
        let duplicate = SmartQuietNotificationPolicy.evaluate(
            state: state,
            observation: observation(sessions: [session(id: "completed", status: .completed)])
        )

        #expect(completion.notifications.map(\.kind) == [.sessionCompleted])
        #expect(duplicate.notifications.isEmpty)
    }

    @Test("Failure and disconnect transitions are actionable")
    func failureAndDisconnectNotify() {
        let active = session(id: "failed", status: .active)
        let connected = provider(connection: .connected, usage: nil)
        let baseline = SmartQuietNotificationPolicy.evaluate(
            state: .init(),
            observation: observation(providers: [connected], sessions: [active])
        )
        let result = SmartQuietNotificationPolicy.evaluate(
            state: baseline.state,
            observation: observation(
                providers: [provider(connection: .failed, usage: nil)],
                sessions: [session(id: "failed", status: .failed)]
            )
        )

        #expect(result.notifications.map(\.kind) == [.sessionFailed, .providerDisconnected])
    }

    @Test("Usage thresholds fire once per quota cycle")
    func thresholdsAreDeduplicated() {
        var state = evaluate(.init(), usage: 70).state
        let warning = evaluate(state, usage: 85)
        state = warning.state
        let progress = evaluate(state, usage: 92)
        state = progress.state
        let exhausted = evaluate(state, usage: 100)
        state = exhausted.state
        let duplicate = evaluate(state, usage: 100)

        #expect(warning.notifications.map(\.kind) == [.usageThreshold(.warning)])
        #expect(progress.notifications.isEmpty)
        #expect(exhausted.notifications.map(\.kind) == [.usageThreshold(.exhausted)])
        #expect(duplicate.notifications.isEmpty)
    }

    @Test("A jump to 100 percent produces only the highest alert")
    func thresholdJumpIsCoalesced() {
        let baseline = evaluate(.init(), usage: 70)
        let result = evaluate(baseline.state, usage: 100)

        #expect(result.notifications.map(\.kind) == [.usageThreshold(.exhausted)])
    }

    @Test("An open-ended quota can notify again after a clear reset")
    func openCycleResetRearmsThreshold() {
        var state = evaluate(.init(), usage: 70).state
        state = evaluate(state, usage: 85).state
        state = evaluate(state, usage: 100).state
        state = evaluate(state, usage: 5).state
        let nextCycle = evaluate(state, usage: 82)

        #expect(nextCycle.notifications.map(\.kind) == [.usageThreshold(.warning)])
    }

    @Test("Launching into existing high usage does not create noise")
    func initialHighUsageIsBaselineOnly() {
        let initial = evaluate(.init(), usage: 85)
        let exhausted = evaluate(initial.state, usage: 100)

        #expect(initial.notifications.isEmpty)
        #expect(exhausted.notifications.map(\.kind) == [.usageThreshold(.exhausted)])
    }

    @Test("Duplicate public identifiers use the last observation without trapping")
    func duplicateIdentifiersAreDeterministic() {
        let duplicateProvider = provider(connection: .connected, usage: 10)
        let latestProvider = provider(connection: .connected, usage: 70)
        let baseline = SmartQuietNotificationPolicy.evaluate(
            state: .init(),
            observation: observation(providers: [duplicateProvider, latestProvider])
        )
        let duplicateQuotaProvider = NotificationProviderObservation(
            id: .codex,
            connection: .connected,
            quotas: [
                .init(id: "five-hour", label: "old", usedPercent: 20, resetsAt: nil),
                .init(id: "five-hour", label: "latest", usedPercent: 85, resetsAt: nil),
            ]
        )

        let result = SmartQuietNotificationPolicy.evaluate(
            state: baseline.state,
            observation: observation(providers: [duplicateQuotaProvider])
        )

        #expect(result.notifications.map(\.kind) == [.usageThreshold(.warning)])
    }

    private func evaluate(
        _ state: SmartQuietPolicyState,
        usage: Double
    ) -> SmartQuietEvaluation {
        SmartQuietNotificationPolicy.evaluate(
            state: state,
            observation: observation(providers: [provider(connection: .connected, usage: usage)])
        )
    }

    private func observation(
        providers: [NotificationProviderObservation] = [],
        sessions: [NotificationSessionObservation] = []
    ) -> SmartQuietObservation {
        .init(providers: providers, sessions: sessions, approvals: [])
    }

    private func provider(
        connection: NotificationConnectionState,
        usage: Double?
    ) -> NotificationProviderObservation {
        let quotas = usage.map {
            [NotificationQuotaObservation(id: "five-hour", label: "5 hour", usedPercent: $0, resetsAt: nil)]
        } ?? []
        return .init(id: .codex, connection: connection, quotas: quotas)
    }

    private func session(
        id: String,
        status: NotificationSessionStatus
    ) -> NotificationSessionObservation {
        .init(id: id, provider: .codex, projectName: "NotchHub", status: status)
    }
}
