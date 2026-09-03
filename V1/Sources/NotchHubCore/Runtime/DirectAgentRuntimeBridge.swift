import Foundation

public extension DirectAgentRuntime {
    /// Applies already-sanitized Claude status-line quota data delivered by the
    /// authenticated bridge. It never receives the original status-line JSON.
    func ingestClaudeStatusLine(_ event: BridgeStatusLineEvent) async -> ProviderRuntimeState {
        do {
            let windows = try event.rateLimits.map(Self.quotaWindow(from:))
            guard !windows.isEmpty else {
                throw ProviderError.invalidPayload(provider: .claude, field: "status-line quota windows")
            }
            let snapshot = try UsageSnapshot(
                provider: .claude,
                windows: windows,
                capturedAt: event.capturedAt
            )
            lastGoodSnapshots[.claude] = snapshot
            states[.claude] = ProviderRuntimeState(
                provider: .claude,
                connectionState: .connected(lastRefresh: snapshot.capturedAt),
                usageSnapshot: snapshot,
                snapshotSource: .liveProvider,
                executableSource: executables[.claude]?.source
            )
            await persistLastGoodSnapshots()
        } catch {
            await applyFailure(
                ProviderError.wrapping(error, provider: .claude),
                provider: .claude,
                operation: "status-line"
            )
        }
        return resolvedState(for: .claude)
    }

    private nonisolated static func quotaWindow(from value: BridgeRateLimitWindow) throws -> QuotaWindow {
        let metadata: (label: String, duration: Int) = switch value.id {
        case .fiveHour: ("5 hour", 300)
        case .sevenDay: ("7 day", 10_080)
        }
        return try QuotaWindow(
            id: value.id.rawValue,
            label: metadata.label,
            usedPercent: value.usedPercent,
            resetsAt: value.resetsAt,
            windowDurationMinutes: metadata.duration
        )
    }
}
