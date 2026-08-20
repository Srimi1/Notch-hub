import CoreFoundation
import Foundation

/// Per-provider credit/spend fetch. Each fetcher takes the secret as a parameter
/// (it never reads the Keychain itself — that's the service's job) and returns an
/// honest, labeled `ProviderMetric`. All response parsing lives in `static`
/// helpers so it's unit-testable without a network.
protocol CreditFetcher: Sendable {
    var provider: CreditProvider { get }
    func fetch(
        secret: String, teamID: String?, allowRateLimitProbe: Bool, client: APIClient
    ) async -> ProviderMetric
}

// MARK: - Shared parsing helpers

enum CreditParse {
    static func dictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderMetricError.malformedResponse
            }
            return dictionary
        } catch is ProviderMetricError {
            throw ProviderMetricError.malformedResponse
        } catch {
            throw ProviderMetricError.malformedResponse
        }
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = double(value) else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    static func double(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            parsed = number.doubleValue
        case let string as String:
            parsed = Double(string)
        default:
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    static func dollars(cents: Double) -> Double? {
        let dollars = cents / 100.0
        return dollars.isFinite ? dollars : nil
    }
}

enum CreditTime {
    /// First instant of the current UTC month.
    static func monthStart(_ now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let comps = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: comps) ?? now
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .gmt
        return formatter.string(from: date)
    }

    /// (startISO, exclusiveEndISO) covering every UTC day in the current month
    /// through today. Anthropic emits only buckets ending before `ending_at`, so
    /// the exclusive end must be the next UTC midnight rather than `now`.
    static func monthWindowISO8601(_ now: Date = Date()) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(86_400)
        return (iso8601(monthStart(now)), iso8601(exclusiveEnd))
    }

    /// Unix seconds at the start of the current month — for OpenAI's costs query.
    static func monthStartUnix(_ now: Date = Date()) -> Int {
        Int(monthStart(now).timeIntervalSince1970)
    }

    static func unix(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970)
    }
}

private enum CreditFetchErrorRouter {
    static func metric(for error: Error, operation: String) -> ProviderMetric {
        let routedError: ProviderMetricError
        switch error {
        case let providerError as ProviderMetricError:
            routedError = providerError
        case APIClient.HTTPError.offline:
            routedError = .offline
        case APIClient.HTTPError.transport, APIClient.HTTPError.cancelled:
            routedError = .transport
        case APIClient.HTTPError.responseTooLarge:
            routedError = .malformedResponse
        case APIClient.HTTPError.unsafeRedirect:
            routedError = .unsafeRedirect
        default:
            routedError = .transport
        }

        NSLog(
            "NotchHub credits: %@ failed (%@)",
            operation,
            String(reflecting: type(of: error))
        )
        return .failure(routedError)
    }
}

// MARK: - Grok (xAI) — real prepaid BALANCE

struct GrokFetcher: CreditFetcher {
    let provider = CreditProvider.grok

    /// Documented xAI Management API surface. Note the asymmetry: the billing
    /// endpoints are versioned, the auth endpoints are not.
    static let managementHost = "https://management-api.x.ai"
    static let keyValidationURL = URL(string: "\(managementHost)/auth/management-keys/validation")

    static func balanceURL(teamID: String) -> URL? {
        URL(string: "\(managementHost)/v1/billing/teams/\(teamID)/prepaid/balance")
    }

    func fetch(
        secret: String, teamID: String?, allowRateLimitProbe: Bool, client: APIClient
    ) async -> ProviderMetric {
        let team: String
        do {
            team = try await resolvedTeamID(
                configured: teamID ?? "",
                secret: secret,
                client: client
            )
        } catch {
            return CreditFetchErrorRouter.metric(for: error, operation: "xAI team lookup")
        }

        guard let url = Self.balanceURL(teamID: team) else { return .failure(.malformedResponse) }

        do {
            let response = try await client.get(url, headers: ["Authorization": "Bearer \(secret)"])
            switch response.status {
            case 200:
                return .balance(usd: try Self.parseBalanceUSD(response.data))
            case 401: return .failure(.unauthorized)
            case 403: return .failure(.forbidden("Key lacks billing access"))
            case 404: return .failure(.forbidden("Team not found — check team ID"))
            default: return .failure(.badResponse(status: response.status))
            }
        } catch {
            return CreditFetchErrorRouter.metric(for: error, operation: "xAI balance")
        }
    }

    private func resolvedTeamID(
        configured: String,
        secret: String,
        client: APIClient
    ) async throws -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let teamID = CreditInputValidator.teamID(trimmed) else {
                throw ProviderMetricError.invalidTeamID
            }
            return teamID
        }

        // No team ID set — try to resolve it from the Management key itself so
        // the user doesn't have to hunt for it. Falls back to "set team ID".
        guard let resolved = try await resolveTeamID(secret: secret, client: client) else {
            throw ProviderMetricError.missingTeamID
        }
        guard let teamID = CreditInputValidator.teamID(resolved) else {
            throw ProviderMetricError.invalidTeamID
        }
        return teamID
    }

    /// Resolve the team ID from the Management key via the key-validation
    /// endpoint, so a balance can be fetched without the user supplying it.
    ///
    /// The documented path is `/auth/management-keys/validation` — **not**
    /// `/v1/auth/...`. Only the billing endpoints carry the `/v1` prefix.
    private func resolveTeamID(secret: String, client: APIClient) async throws -> String? {
        guard let url = Self.keyValidationURL else {
            throw ProviderMetricError.malformedResponse
        }

        let response = try await client.get(url, headers: ["Authorization": "Bearer \(secret)"])
        switch response.status {
        case 200: return try Self.parseTeamID(response.data)
        case 401: throw ProviderMetricError.unauthorized
        case 403: throw ProviderMetricError.forbidden("Key lacks team access")
        default: throw ProviderMetricError.badResponse(status: response.status)
        }
    }

    /// Pull a team id out of the key-validation response. xAI documents
    /// `teamId` as deprecated in favour of `scope` + `scopeId`, so `scopeId` is
    /// preferred when the key is scoped to a team; both spellings and a nested
    /// key object are accepted defensively.
    static func parseTeamID(_ data: Data) throws -> String? {
        let json = try CreditParse.dictionary(data)
        if let scoped = teamScopedID(in: json) { return scoped }
        if let nested = json["managementKey"] as? [String: Any],
           let scoped = teamScopedID(in: nested) {
            return scoped
        }
        return nil
    }

    private static func teamScopedID(in json: [String: Any]) -> String? {
        let scope = (json["scope"] as? String)?.lowercased() ?? ""
        if scope.contains("team"), let value = nonEmptyString(json["scopeId"] ?? json["scope_id"]) {
            return value
        }
        if let value = nonEmptyString(json["teamId"] ?? json["team_id"]) { return value }
        return nonEmptyString(json["scopeId"] ?? json["scope_id"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// xAI returns the prepaid balance as `total.val` in USD cents. Legacy
    /// scalar and `amount` shapes remain accepted defensively.
    static func parseBalanceUSD(_ data: Data) throws -> Double {
        let json = try CreditParse.dictionary(data)
        if let cents = CreditParse.double(json["total"]),
           let dollars = CreditParse.dollars(cents: cents) {
            return dollars
        }
        if let nested = json["total"] as? [String: Any] {
            if let cents = CreditParse.double(nested["val"]),
               let dollars = CreditParse.dollars(cents: cents) {
                return dollars
            }
            if let cents = CreditParse.double(nested["amount"]),
               let dollars = CreditParse.dollars(cents: cents) {
                return dollars
            }
        }
        if let cents = CreditParse.double(json["balance"]),
           let dollars = CreditParse.dollars(cents: cents) {
            return dollars
        }
        throw ProviderMetricError.malformedResponse
    }
}

// MARK: - Anthropic — SPEND (admin key) or rate-limit probe (standard key)

struct AnthropicFetcher: CreditFetcher {
    let provider = CreditProvider.anthropic

    enum KeyType: Equatable, Sendable { case admin, standard, unknown }

    static func keyType(_ secret: String) -> KeyType {
        if secret.hasPrefix("sk-ant-admin") { return .admin }
        if secret.hasPrefix("sk-ant-") { return .standard }
        return .unknown
    }

    func fetch(
        secret: String, teamID: String?, allowRateLimitProbe: Bool, client: APIClient
    ) async -> ProviderMetric {
        switch Self.keyType(secret) {
        case .admin:
            return await fetchSpend(secret: secret, client: client)
        case .standard:
            guard allowRateLimitProbe else { return .unsupported(reason: "Add an Admin key for spend") }
            return await probeRateLimit(secret: secret, client: client)
        case .unknown:
            return .failure(.notConfigured)
        }
    }

    private func fetchSpend(secret: String, client: APIClient) async -> ProviderMetric {
        guard let url = Self.costReportURL() else { return .failure(.malformedResponse) }

        do {
            let response = try await client.get(url, headers: [
                "x-api-key": secret,
                "anthropic-version": "2023-06-01"
            ])
            switch response.status {
            case 200:
                // Priority Tier usage is billed under a different model and is
                // absent from the cost report, so this is explicitly a partial
                // total rather than the whole account's spend.
                return .spend(
                    usd: try Self.parseCostUSD(response.data),
                    period: .month,
                    scope: .excludingPriorityTier
                )
            case 401: return .failure(.unauthorized)
            case 403: return .failure(.forbidden("Admin key needs an Organization"))
            default: return .failure(.badResponse(status: response.status))
            }
        } catch {
            return CreditFetchErrorRouter.metric(for: error, operation: "Anthropic spend")
        }
    }

    private func probeRateLimit(secret: String, client: APIClient) async -> ProviderMetric {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .failure(.malformedResponse)
        }
        let payload: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return CreditFetchErrorRouter.metric(
                for: ProviderMetricError.malformedResponse,
                operation: "Anthropic probe payload"
            )
        }
        do {
            let response = try await client.post(
                url,
                headers: [
                    "x-api-key": secret,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json"
                ],
                body: body,
                maxRetries: 0
            )
            if response.status == 401 { return .failure(.unauthorized) }
            switch response.status {
            case 200 ... 299, 429:
                return try Self.parseRateLimit(response.headers)
            case 403:
                return .failure(.forbidden("Key lacks Messages access"))
            default:
                return .failure(.badResponse(status: response.status))
            }
        } catch {
            return CreditFetchErrorRouter.metric(for: error, operation: "Anthropic rate-limit probe")
        }
    }

    /// A UTC month contains at most 31 daily buckets. `ending_at` is the next
    /// UTC midnight because the API includes only buckets ending before it.
    static func costReportURL(now: Date = Date()) -> URL? {
        let (start, end) = CreditTime.monthWindowISO8601(now)
        var components = URLComponents(
            string: "https://api.anthropic.com/v1/organizations/cost_report"
        )
        components?.queryItems = [
            URLQueryItem(name: "starting_at", value: start),
            URLQueryItem(name: "ending_at", value: end),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        return components?.url
    }

    /// Cost report: sum `data[].results[].amount` (USD cents as decimal strings).
    static func parseCostUSD(_ data: Data) throws -> Double {
        let json = try CreditParse.dictionary(data)
        guard json["has_more"] as? Bool != true else {
            throw ProviderMetricError.incompleteReport
        }
        guard let rows = json["data"] as? [[String: Any]] else {
            throw ProviderMetricError.malformedResponse
        }
        var cents = 0.0
        for row in rows {
            guard let results = row["results"] as? [[String: Any]] else {
                throw ProviderMetricError.malformedResponse
            }
            for result in results {
                guard let amount = CreditParse.double(result["amount"]),
                      (result["currency"] as? String)?.uppercased() == "USD" else {
                    throw ProviderMetricError.malformedResponse
                }
                cents += amount
                guard cents.isFinite else { throw ProviderMetricError.malformedResponse }
            }
        }
        guard let dollars = CreditParse.dollars(cents: cents) else {
            throw ProviderMetricError.malformedResponse
        }
        return dollars
    }

    static func parseRateLimit(_ headers: [String: String]) throws -> ProviderMetric {
        let requests = headers["anthropic-ratelimit-requests-remaining"].flatMap { Int($0) }
        let tokens = headers["anthropic-ratelimit-tokens-remaining"].flatMap { Int($0) }
        guard requests != nil || tokens != nil else {
            throw ProviderMetricError.malformedResponse
        }
        return .rateLimit(remainingRequests: requests, remainingTokens: tokens)
    }
}

// MARK: - OpenAI / Codex — SPEND (admin key) or "not supported"

struct OpenAIFetcher: CreditFetcher {
    let provider = CreditProvider.openai

    func fetch(
        secret: String, teamID: String?, allowRateLimitProbe: Bool, client: APIClient
    ) async -> ProviderMetric {
        guard let url = Self.costReportURL() else { return .failure(.malformedResponse) }

        do {
            let response = try await client.get(url, headers: ["Authorization": "Bearer \(secret)"])
            switch response.status {
            case 200:
                return .spend(
                    usd: try Self.parseCostUSD(response.data),
                    period: .month,
                    scope: .complete
                )
            case 401, 403:
                // A non-admin key can't read org costs, and OpenAI has no balance
                // endpoint — so this is "not supported", not an error.
                return .unsupported(reason: "Needs an Admin key")
            default:
                return .failure(.badResponse(status: response.status))
            }
        } catch {
            return CreditFetchErrorRouter.metric(for: error, operation: "OpenAI spend")
        }
    }

    /// A UTC month contains at most 31 daily buckets, below OpenAI's 180-bucket
    /// maximum. An explicit 31-bucket limit prevents the seven-day default from
    /// silently truncating month-to-date spend.
    static func costReportURL(now: Date = Date()) -> URL? {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")
        components?.queryItems = [
            URLQueryItem(name: "start_time", value: String(CreditTime.monthStartUnix(now))),
            URLQueryItem(name: "end_time", value: String(CreditTime.unix(now))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        return components?.url
    }

    /// Costs: sum `data[].results[].amount.value` (USD dollars).
    static func parseCostUSD(_ data: Data) throws -> Double {
        let json = try CreditParse.dictionary(data)
        guard json["has_more"] as? Bool != true else {
            throw ProviderMetricError.incompleteReport
        }
        guard let buckets = json["data"] as? [[String: Any]] else {
            throw ProviderMetricError.malformedResponse
        }
        var dollars = 0.0
        for bucket in buckets {
            guard let results = bucket["results"] as? [[String: Any]] else {
                throw ProviderMetricError.malformedResponse
            }
            for result in results {
                guard let amount = result["amount"] as? [String: Any],
                      let value = CreditParse.double(amount["value"]),
                      (amount["currency"] as? String)?.lowercased() == "usd" else {
                    throw ProviderMetricError.malformedResponse
                }
                dollars += value
                guard dollars.isFinite else { throw ProviderMetricError.malformedResponse }
            }
        }
        return dollars
    }
}

// MARK: - Google / Gemini — honest placeholder (no API-key balance exists)

struct GoogleFetcher: CreditFetcher {
    let provider = CreditProvider.google

    func fetch(
        secret: String, teamID: String?, allowRateLimitProbe: Bool, client: APIClient
    ) async -> ProviderMetric {
        .unsupported(reason: "Not supported via API key")
    }
}
