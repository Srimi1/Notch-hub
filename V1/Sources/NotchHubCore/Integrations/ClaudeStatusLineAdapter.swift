import Foundation

public actor ClaudeStatusLineUsageAdapter: UsageProviderAdapter {
    public nonisolated let provider = ProviderID.claude
    public static let maximumPayloadBytes = 65_536

    private var latestSnapshot: UsageSnapshot?

    public init() {}

    public func ingest(
        _ data: Data,
        capturedAt: Date = Date()
    ) throws {
        guard data.count <= Self.maximumPayloadBytes else {
            throw ProviderError.malformedResponse(provider: .claude)
        }
        let payload: ClaudeStatusLinePayload
        do {
            payload = try JSONDecoder().decode(ClaudeStatusLinePayload.self, from: data)
        } catch {
            throw ProviderError.malformedResponse(provider: .claude)
        }
        latestSnapshot = try payload.snapshot(capturedAt: capturedAt)
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let latestSnapshot else {
            throw ProviderError.adapterUnavailable(provider: .claude)
        }
        return latestSnapshot
    }

    public func clear() {
        latestSnapshot = nil
    }
}

private struct ClaudeStatusLinePayload: Decodable {
    let rateLimits: ClaudeRateLimits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }

    func snapshot(capturedAt: Date) throws -> UsageSnapshot {
        guard let rateLimits else {
            throw ProviderError.adapterUnavailable(provider: .claude)
        }
        var windows: [QuotaWindow] = []
        if let fiveHour = rateLimits.fiveHour, let window = try fiveHour.quotaWindow(
            id: "claude.five-hour",
            label: "Claude 5-hour",
            durationMinutes: 300
        ) {
            windows.append(window)
        }
        if let sevenDay = rateLimits.sevenDay, let window = try sevenDay.quotaWindow(
            id: "claude.seven-day",
            label: "Claude 7-day",
            durationMinutes: 10_080
        ) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw ProviderError.adapterUnavailable(provider: .claude)
        }
        return try UsageSnapshot(
            provider: .claude,
            windows: windows,
            capturedAt: capturedAt
        )
    }
}

private struct ClaudeRateLimits: Decodable {
    let fiveHour: ClaudeRateLimitWindow?
    let sevenDay: ClaudeRateLimitWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeRateLimitWindow: Decodable {
    let usedPercentage: Double?
    let resetsAt: Double?

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    func quotaWindow(
        id: String,
        label: String,
        durationMinutes: Int
    ) throws -> QuotaWindow? {
        guard let usedPercentage else {
            return nil
        }
        return try QuotaWindow(
            id: id,
            label: label,
            usedPercent: usedPercentage,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) },
            windowDurationMinutes: durationMinutes
        )
    }
}
