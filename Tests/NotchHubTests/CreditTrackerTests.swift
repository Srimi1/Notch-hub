import Foundation
import Testing
@testable import NotchHub

private actor CreditFetchGate {
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var allowProbeValues: [Bool] = []

    var callCount: Int { allowProbeValues.count }

    func fetch(allowProbe: Bool) async -> ProviderMetric {
        allowProbeValues.append(allowProbe)
        if allowProbeValues.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return .rateLimit(remainingRequests: 1, remainingTokens: 1)
    }

    func releaseFirstFetch() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private struct GatedAnthropicFetcher: CreditFetcher {
    let provider = CreditProvider.anthropic
    let gate: CreditFetchGate

    func fetch(
        secret: String,
        teamID: String?,
        allowRateLimitProbe: Bool,
        client: APIClient
    ) async -> ProviderMetric {
        await gate.fetch(allowProbe: allowRateLimitProbe)
    }
}

// swift-testing suites for the adaptive API-key credit/spend tracker. These cover
// the pure, honest-by-construction surface: the metric model, key-type detection,
// response parsing (no network), and the Keychain round-trip.

@Suite("CreditModel")
struct ProviderMetricTests {

    @Test
    func googleIsTheOnlyProviderWithoutAnAPIKeyMetric() {
        #expect(CreditProvider.google.supportsAPIKeyMetric == false)
        #expect(CreditProvider.grok.supportsAPIKeyMetric == true)
        #expect(CreditProvider.anthropic.supportsAPIKeyMetric == true)
        #expect(CreditProvider.openai.supportsAPIKeyMetric == true)
    }

    @Test
    func providerRawValuesAreDistinct() {
        let raws = CreditProvider.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test
    func metricLabelsAreHonest() {
        #expect(ProviderMetric.balance(usd: 12.5).label == "Balance")
        #expect(
            ProviderMetric.spend(usd: 3, period: .month, scope: .complete).label
                == "Spent this month"
        )
        #expect(ProviderMetric.unsupported(reason: "x").label == "Not supported")
        #expect(ProviderMetric.failure(.offline).label == "Error")
        #expect(ProviderMetric.loading.label == "Loading…")
    }

    /// Anthropic's cost report omits Priority Tier usage, so its spend figure
    /// must never be presented as a complete account total.
    @Test
    func partialSpendIsLabelledAndDisclosed() {
        let partial = ProviderMetric.spend(usd: 42, period: .month, scope: .excludingPriorityTier)
        #expect(partial.label == "Spent this month · excl. Priority Tier")
        #expect(partial.disclosure?.contains("Priority Tier") == true)

        let complete = ProviderMetric.spend(usd: 42, period: .month, scope: .complete)
        #expect(complete.label == "Spent this month")
        #expect(complete.disclosure == nil)
        #expect(ProviderMetric.balance(usd: 1).disclosure == nil)
    }

    /// A retained financial number must say *why* it is stale and *how old* it
    /// is — an orange indicator alone is not informed consent.
    @Test
    func retainedValuesDiscloseTheirStalenessAndAge() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        let live = ProviderResult(
            provider: .grok, metric: .balance(usd: 5), lastUpdated: fetched
        )
        #expect(live.isStale == false)
        #expect(live.staleDisclosure(now: fetched) == nil)

        let stale = ProviderResult(
            provider: .grok,
            metric: .balance(usd: 5),
            lastUpdated: fetched,
            staleReason: .fetchFailed(.offline)
        )
        #expect(stale.isStale)
        #expect(stale.staleDisclosure(now: fetched.addingTimeInterval(45)) == "Offline · 45s old")
        #expect(stale.staleDisclosure(now: fetched.addingTimeInterval(720)) == "Offline · 12m old")
        #expect(stale.staleDisclosure(now: fetched.addingTimeInterval(7_200)) == "Offline · 2h old")
        #expect(
            stale.staleDisclosure(now: fetched.addingTimeInterval(172_800)) == "Offline · 2d old"
        )

        let deferred = ProviderResult(
            provider: .anthropic,
            metric: .rateLimit(remainingRequests: 1, remainingTokens: 1),
            lastUpdated: nil,
            staleReason: .manualProbeRequired
        )
        #expect(deferred.staleDisclosure(now: fetched) == "Manual refresh needed")
    }

    /// The xAI Management API versions its billing endpoints but *not* its auth
    /// endpoints — a `/v1` prefix on key validation silently 404s.
    @Test
    func usesTheDocumentedXAIManagementPaths() throws {
        let validation = try #require(GrokFetcher.keyValidationURL)
        #expect(
            validation.absoluteString
                == "https://management-api.x.ai/auth/management-keys/validation"
        )

        let balance = try #require(GrokFetcher.balanceURL(teamID: "team_123"))
        #expect(
            balance.absoluteString
                == "https://management-api.x.ai/v1/billing/teams/team_123/prepaid/balance"
        )
    }

    /// `teamId` is documented as deprecated in favour of `scope` + `scopeId`.
    @Test
    func prefersScopedTeamIdentifierOverTheDeprecatedField() throws {
        let scoped = Data(#"{"scope":"SCOPE_TEAM","scopeId":"team_scoped","teamId":"legacy"}"#.utf8)
        let legacyOnly = Data(#"{"teamId":"legacy"}"#.utf8)
        let nested = Data(#"{"managementKey":{"scope":"team","scopeId":"nested_team"}}"#.utf8)

        #expect(try GrokFetcher.parseTeamID(scoped) == "team_scoped")
        #expect(try GrokFetcher.parseTeamID(legacyOnly) == "legacy")
        #expect(try GrokFetcher.parseTeamID(nested) == "nested_team")
        #expect(try GrokFetcher.parseTeamID(Data(#"{}"#.utf8)) == nil)
    }

    @Test
    func errorMessagesAreNeverEmpty() {
        let errors: [ProviderMetricError] = [
            .offline, .transport, .unauthorized, .forbidden("needs an Organization"),
            .missingTeamID, .invalidTeamID, .notConfigured, .credentialStore,
            .badResponse(status: 500), .malformedResponse, .incompleteReport, .unsafeRedirect
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
        }
    }

    @Test
    func loadingDefaultResultIsHonest() {
        let result = ProviderResult(provider: .grok)
        #expect(result.metric == .loading)
        #expect(result.lastUpdated == nil)
        #expect(result.isStale == false)
        #expect(result.id == "grok")
    }

    @Test
    func validatesCredentialsAndTeamIDsBeforeUse() {
        #expect(CreditInputValidator.credential(" sk-ant-example ") == "sk-ant-example")
        #expect(CreditInputValidator.credential("key with spaces") == nil)
        #expect(CreditInputValidator.credential("key\nvalue") == nil)
        #expect(CreditInputValidator.teamID("team_123-abc") == "team_123-abc")
        #expect(CreditInputValidator.teamID("../billing") == nil)
        #expect(CreditInputValidator.teamID(String(repeating: "a", count: 129)) == nil)
    }

    @Test
    func parsesProviderResponsesWithoutFabricatingValues() throws {
        let grok = Data(#"{"total":{"val":"1250"}}"#.utf8)
        let anthropic = Data(
            #"{"data":[{"results":[{"amount":"325","currency":"USD"}]}],"has_more":false}"#.utf8
        )
        let openAI = Data(
            #"{"data":[{"results":[{"amount":{"value":4.75,"currency":"usd"}}]}],"has_more":false}"#.utf8
        )
        let team = Data(#"{"managementKey":{"team_id":"team_123"}}"#.utf8)

        #expect(try GrokFetcher.parseBalanceUSD(grok) == 12.5)
        #expect(try AnthropicFetcher.parseCostUSD(anthropic) == 3.25)
        #expect(try OpenAIFetcher.parseCostUSD(openAI) == 4.75)
        #expect(try GrokFetcher.parseTeamID(team) == "team_123")
        #expect(throws: ProviderMetricError.malformedResponse) {
            try GrokFetcher.parseBalanceUSD(Data("not-json".utf8))
        }
        #expect(throws: ProviderMetricError.incompleteReport) {
            try OpenAIFetcher.parseCostUSD(Data(#"{"data":[],"has_more":true}"#.utf8))
        }
    }

    @Test
    func rejectsNonFiniteAndNonNumericFinancialValues() {
        #expect(CreditParse.double("NaN") == nil)
        #expect(CreditParse.double("Infinity") == nil)
        #expect(CreditParse.double(Double.infinity) == nil)
        #expect(CreditParse.double(true) == nil)
        #expect(CreditParse.int("1e1000") == nil)

        #expect(throws: ProviderMetricError.malformedResponse) {
            try GrokFetcher.parseBalanceUSD(Data(#"{"total":{"val":"NaN"}}"#.utf8))
        }
        #expect(throws: ProviderMetricError.malformedResponse) {
            try AnthropicFetcher.parseCostUSD(
                Data(#"{"data":[{"results":[{"amount":"Infinity","currency":"USD"}]}]}"#.utf8)
            )
        }
        #expect(throws: ProviderMetricError.malformedResponse) {
            try OpenAIFetcher.parseCostUSD(
                Data(#"{"data":[{"results":[{"amount":{"value":"NaN","currency":"usd"}}]}]}"#.utf8)
            )
        }
    }

    @Test
    func requestsCompleteMonthRangesAndUsesDocumentedRateHeaders() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let now = try #require(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 15, minute: 30
        )))
        let expectedAnthropicEnd = try #require(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 21
        )))
        let anthropicURL = try #require(AnthropicFetcher.costReportURL(now: now))
        let openAIURL = try #require(OpenAIFetcher.costReportURL(now: now))
        let anthropicQuery = queryItems(in: anthropicURL)
        let openAIQuery = queryItems(in: openAIURL)

        #expect(anthropicQuery["bucket_width"] == "1d")
        #expect(anthropicQuery["limit"] == "31")
        #expect(anthropicQuery["starting_at"] != nil)
        #expect(anthropicQuery["ending_at"] == CreditTime.iso8601(expectedAnthropicEnd))
        #expect(openAIQuery["bucket_width"] == "1d")
        #expect(openAIQuery["limit"] == "31")
        #expect(openAIQuery["start_time"] != nil)
        #expect(openAIQuery["end_time"] != nil)

        let metric = try AnthropicFetcher.parseRateLimit([
            "anthropic-ratelimit-requests-remaining": "42",
            "anthropic-ratelimit-tokens-remaining": "9000"
        ])
        #expect(metric == .rateLimit(remainingRequests: 42, remainingTokens: 9000))
        #expect(throws: ProviderMetricError.malformedResponse) {
            try AnthropicFetcher.parseRateLimit([:])
        }
    }

    @Test
    @MainActor
    func coalescesRefreshesWithoutDroppingManualProbeIntent() async {
        let suite = "CreditTrackerTests.\(UUID().uuidString)"
        let defaults = try? #require(UserDefaults(suiteName: suite))
        guard let defaults else { return }
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = CreditPreferences(defaults: defaults)
        let gate = CreditFetchGate()
        let service = CreditTrackerService(
            prefs: prefs,
            fetchers: [.anthropic: GatedAnthropicFetcher(gate: gate)],
            credentialReader: { account in
                account == CreditProvider.anthropic.rawValue ? "sk-ant-test" : nil
            }
        )

        let firstRefresh = Task { await service.refresh(allowBillableProbe: false) }
        while await gate.callCount == 0 { await Task.yield() }
        prefs.anthropicRateLimitProbe = true
        await service.refresh(allowBillableProbe: true)
        await gate.releaseFirstFetch()
        await firstRefresh.value

        #expect(await gate.allowProbeValues == [false, true])
    }

    private func queryItems(in url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

@Suite("Keychain")
struct KeychainStoreTests {

    // Isolated service name so tests never touch the user's real API keys.
    private let testService = "com.notchhub.apikeys.test"

    @Test
    func roundTripsSaveReadUpdateDelete() throws {
        let account = "rt-\(UUID().uuidString)"

        // Some environments (unsigned CI runners) can't reach the keychain at all;
        // if the first write fails, treat the keychain as unavailable and bail
        // rather than failing the suite.
        do {
            try KeychainStore.save("secret-value", account: account, service: testService)
        } catch {
            NSLog("NotchHub tests: Keychain unavailable (%@)", String(reflecting: type(of: error)))
            return
        }
        defer {
            do {
                try KeychainStore.delete(account: account, service: testService)
            } catch {
                Issue.record("Could not clean up Keychain fixture: \(error.localizedDescription)")
            }
        }

        #expect(try KeychainStore.read(account: account, service: testService) == "secret-value")
        #expect(try KeychainStore.hasKey(account: account, service: testService) == true)

        // Add-or-update overwrites in place.
        try KeychainStore.save("rotated-value", account: account, service: testService)
        #expect(try KeychainStore.read(account: account, service: testService) == "rotated-value")

        // Delete is idempotent and leaves no trace.
        try KeychainStore.delete(account: account, service: testService)
        try KeychainStore.delete(account: account, service: testService)
        #expect(try KeychainStore.read(account: account, service: testService) == nil)
        #expect(try KeychainStore.hasKey(account: account, service: testService) == false)
    }

    @Test
    func readingAMissingItemReturnsNil() throws {
        let account = "missing-\(UUID().uuidString)"
        #expect(try KeychainStore.read(account: account, service: testService) == nil)
        #expect(try KeychainStore.hasKey(account: account, service: testService) == false)
    }
}
