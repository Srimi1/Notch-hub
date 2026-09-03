import Foundation

/// A deterministic reducer. It has no timers, authorization prompts, delivery,
/// persistence, or telemetry; callers explicitly retain the returned state.
public enum SmartQuietNotificationPolicy {
    private static let rememberedEventLimit = 256
    private static let rememberedQuotaCycleLimit = 64

    public static func evaluate(
        state: SmartQuietPolicyState,
        observation: SmartQuietObservation
    ) -> SmartQuietEvaluation {
        var nextState = state
        var notifications: [SmartQuietNotification] = []

        notifications += approvalNotifications(state: &nextState, current: observation)
        notifications += sessionNotifications(state: &nextState, current: observation)
        notifications += disconnectNotifications(previous: state.previousObservation, current: observation)
        notifications += thresholdNotifications(state: &nextState, current: observation)
        nextState.previousObservation = observation

        return SmartQuietEvaluation(state: nextState, notifications: notifications)
    }

    private static func approvalNotifications(
        state: inout SmartQuietPolicyState,
        current: SmartQuietObservation
    ) -> [SmartQuietNotification] {
        var notifications: [SmartQuietNotification] = []
        let approvals = lastIndexed(current.approvals, by: \.stateKey).values
        for approval in approvals.sorted(by: { $0.stateKey < $1.stateKey }) {
            guard !state.seenApprovalKeys.contains(approval.stateKey) else { continue }
            notifications.append(approvalNotification(approval))
            appendRemembered(approval.stateKey, to: &state.seenApprovalKeys)
        }
        return notifications
    }

    private static func sessionNotifications(
        state: inout SmartQuietPolicyState,
        current: SmartQuietObservation
    ) -> [SmartQuietNotification] {
        let previous = lastIndexed(state.previousObservation?.sessions ?? [], by: \.stateKey)
        var notifications: [SmartQuietNotification] = []
        let sessions = lastIndexed(current.sessions, by: \.stateKey).values
        for session in sessions.sorted(by: { $0.stateKey < $1.stateKey }) {
            guard session.status != .active else { continue }
            let wasActive = previous[session.stateKey]?.status == .active
            if wasActive, !state.seenTerminalSessionKeys.contains(session.stateKey) {
                notifications.append(sessionNotification(session))
            }
            appendRemembered(session.stateKey, to: &state.seenTerminalSessionKeys)
        }
        return notifications
    }

    private static func disconnectNotifications(
        previous: SmartQuietObservation?,
        current: SmartQuietObservation
    ) -> [SmartQuietNotification] {
        guard let previous else { return [] }
        let previousProviders = lastIndexed(previous.providers, by: \.id)
        return lastIndexed(current.providers, by: \.id).values
            .filter { provider in
                previousProviders[provider.id]?.connection.isAvailable == true && provider.connection.isDisconnected
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map(disconnectNotification)
    }

    private static func thresholdNotifications(
        state: inout SmartQuietPolicyState,
        current: SmartQuietObservation
    ) -> [SmartQuietNotification] {
        let hasBaseline = state.previousObservation != nil
        let previousProviders = lastIndexed(state.previousObservation?.providers ?? [], by: \.id)
        var activeCycleKeys = Set<String>()
        var notifications: [SmartQuietNotification] = []

        let providers = lastIndexed(current.providers, by: \.id).values
        for provider in providers.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let previousQuotas = lastIndexed(previousProviders[provider.id]?.quotas ?? [], by: \.id)
            let quotas = lastIndexed(provider.quotas, by: \.id).values
            for quota in quotas.sorted(by: { $0.id < $1.id }) {
                let cycleKey = quota.cycleKey(provider: provider.id)
                activeCycleKeys.insert(cycleKey)
                let previousQuota = previousQuotas[quota.id]
                resetOpenCycleIfNeeded(state: &state, key: cycleKey, previous: previousQuota, current: quota)
                let priorUsage = previousQuota?.usedPercent ?? 0
                let threshold = crossedThreshold(
                    priorUsage: priorUsage,
                    currentUsage: quota.usedPercent,
                    alreadyNotified: state.notifiedThresholds[cycleKey, default: []]
                )
                markReachedThresholds(state: &state, key: cycleKey, usage: quota.usedPercent)
                if hasBaseline, let threshold {
                    notifications.append(thresholdNotification(provider.id, quota: quota, threshold: threshold))
                }
            }
        }
        trimThresholdHistory(state: &state, activeCycleKeys: activeCycleKeys)
        return notifications
    }

    private static func crossedThreshold(
        priorUsage: Double,
        currentUsage: Double,
        alreadyNotified: Set<NotificationUsageThreshold>
    ) -> NotificationUsageThreshold? {
        NotificationUsageThreshold.allCases
            .filter { threshold in
                let value = Double(threshold.rawValue)
                return priorUsage < value && currentUsage >= value && !alreadyNotified.contains(threshold)
            }
            .max { $0.rawValue < $1.rawValue }
    }

    private static func markReachedThresholds(
        state: inout SmartQuietPolicyState,
        key: String,
        usage: Double
    ) {
        for threshold in NotificationUsageThreshold.allCases where usage >= Double(threshold.rawValue) {
            state.notifiedThresholds[key, default: []].insert(threshold)
        }
    }

    private static func resetOpenCycleIfNeeded(
        state: inout SmartQuietPolicyState,
        key: String,
        previous: NotificationQuotaObservation?,
        current: NotificationQuotaObservation
    ) {
        guard current.resetsAt == nil,
              let previous,
              previous.usedPercent >= 80,
              current.usedPercent < 20
        else { return }
        state.notifiedThresholds[key] = []
    }

    private static func appendRemembered(_ key: String, to values: inout [String]) {
        guard !values.contains(key) else { return }
        values.append(key)
        if values.count > rememberedEventLimit {
            values.removeFirst(values.count - rememberedEventLimit)
        }
    }

    private static func trimThresholdHistory(
        state: inout SmartQuietPolicyState,
        activeCycleKeys: Set<String>
    ) {
        guard state.notifiedThresholds.count > rememberedQuotaCycleLimit else { return }
        let inactiveKeys = state.notifiedThresholds.keys
            .filter { !activeCycleKeys.contains($0) }
            .sorted()
        let inactiveCapacity = max(rememberedQuotaCycleLimit - activeCycleKeys.count, 0)
        let retainedKeys = activeCycleKeys.union(inactiveKeys.suffix(inactiveCapacity))
        state.notifiedThresholds = state.notifiedThresholds.filter { retainedKeys.contains($0.key) }
    }

    /// Observations are public input. Last-wins indexing keeps malformed
    /// duplicate identifiers deterministic without the trap imposed by
    /// `Dictionary(uniqueKeysWithValues:)`.
    private static func lastIndexed<Value, Key: Hashable>(
        _ values: [Value],
        by keyPath: KeyPath<Value, Key>
    ) -> [Key: Value] {
        values.reduce(into: [:]) { result, value in
            result[value[keyPath: keyPath]] = value
        }
    }
}

private extension SmartQuietNotificationPolicy {
    static func approvalNotification(_ approval: NotificationApprovalObservation) -> SmartQuietNotification {
        SmartQuietNotification(
            id: "notchhub.v1.approval.\(approval.stateKey)",
            kind: .approval,
            title: "\(approval.provider.displayName) needs approval",
            body: "Review the one-time request for \(approval.projectName) in NotchHub."
        )
    }

    static func sessionNotification(_ session: NotificationSessionObservation) -> SmartQuietNotification {
        let failed = session.status == .failed
        return SmartQuietNotification(
            id: "notchhub.v1.session.\(session.stateKey)",
            kind: failed ? .sessionFailed : .sessionCompleted,
            title: failed ? "\(session.provider.displayName) task failed" :
                "\(session.provider.displayName) task finished",
            body: "\(session.projectName) is \(failed ? "waiting for review" : "complete")."
        )
    }

    static func disconnectNotification(_ provider: NotificationProviderObservation) -> SmartQuietNotification {
        SmartQuietNotification(
            id: "notchhub.v1.disconnected.\(provider.id.rawValue)",
            kind: .providerDisconnected,
            title: "\(provider.id.displayName) disconnected",
            body: "Open NotchHub to review CLI installation or sign-in status."
        )
    }

    static func thresholdNotification(
        _ provider: ProviderID,
        quota: NotificationQuotaObservation,
        threshold: NotificationUsageThreshold
    ) -> SmartQuietNotification {
        SmartQuietNotification(
            id: "notchhub.v1.usage.\(quota.cycleKey(provider: provider)).\(threshold.rawValue)",
            kind: .usageThreshold(threshold),
            title: "\(provider.displayName) usage reached \(threshold.rawValue)%",
            body: "\(quota.label) is now at \(Int(quota.usedPercent.rounded()))%."
        )
    }
}
