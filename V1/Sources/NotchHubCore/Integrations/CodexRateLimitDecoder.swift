import Foundation

enum CodexRateLimitDecoder {
    static func snapshot(from response: Data, capturedAt: Date) throws -> UsageSnapshot {
        let envelope: RateLimitEnvelope
        do {
            envelope = try JSONDecoder().decode(RateLimitEnvelope.self, from: response)
        } catch {
            throw ProviderError.malformedResponse(provider: .codex)
        }
        if let error = envelope.error {
            let normalized = error.message.lowercased()
            if normalized.contains("auth") || normalized.contains("login") || normalized.contains("unauthorized") {
                throw ProviderError.signedOut(provider: .codex)
            }
            throw ProviderError.malformedResponse(provider: .codex)
        }
        guard let result = envelope.result else {
            throw ProviderError.malformedResponse(provider: .codex)
        }
        return try result.snapshot(capturedAt: capturedAt)
    }
}

private struct RateLimitEnvelope: Decodable {
    let result: RateLimitResult?
    let error: RateLimitRPCError?
}

private struct RateLimitRPCError: Decodable {
    let message: String
}

private struct RateLimitResult: Decodable {
    let rateLimits: RateLimitBucket
    let rateLimitsByLimitId: [String: RateLimitBucket]?

    func snapshot(capturedAt: Date) throws -> UsageSnapshot {
        let buckets = normalizedBuckets()
        let windows = try buckets.flatMap { key, bucket in
            try bucket.windows(bucketID: key)
        }
        return try UsageSnapshot(
            provider: .codex,
            windows: windows,
            capturedAt: capturedAt,
            planName: buckets.compactMap(\.value.planType).first,
            creditsRemaining: buckets.compactMap(\.value.credits?.numericBalance).first
        )
    }

    private func normalizedBuckets() -> [(key: String, value: RateLimitBucket)] {
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            return rateLimitsByLimitId.sorted { $0.key < $1.key }
        }
        return [(rateLimits.limitId ?? "codex", rateLimits)]
    }
}

private struct RateLimitBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: RateLimitCredits?
    let planType: String?

    func windows(bucketID: String) throws -> [QuotaWindow] {
        var values: [QuotaWindow] = []
        if let primary {
            values.append(try primary.quotaWindow(
                id: "\(bucketID).primary",
                label: label(for: primary, fallback: "Primary")
            ))
        }
        if let secondary {
            values.append(try secondary.quotaWindow(
                id: "\(bucketID).secondary",
                label: label(for: secondary, fallback: "Secondary")
            ))
        }
        return values
    }

    private func label(for window: RateLimitWindow, fallback: String) -> String {
        let base = limitName ?? limitId ?? "Codex"
        guard let minutes = window.windowDurationMins else {
            return "\(base) \(fallback)"
        }
        if minutes % 10_080 == 0 {
            return "\(base) \(minutes / 10_080)-week"
        }
        if minutes % 1_440 == 0 {
            return "\(base) \(minutes / 1_440)-day"
        }
        if minutes % 60 == 0 {
            return "\(base) \(minutes / 60)-hour"
        }
        return "\(base) \(minutes)-minute"
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    func quotaWindow(id: String, label: String) throws -> QuotaWindow {
        try QuotaWindow(
            id: id,
            label: label,
            usedPercent: Double(usedPercent),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowDurationMinutes: windowDurationMins
        )
    }
}

private struct RateLimitCredits: Decodable {
    let unlimited: Bool
    let balance: String?

    var numericBalance: Double? {
        guard !unlimited, let balance else {
            return nil
        }
        return Double(balance)
    }
}
