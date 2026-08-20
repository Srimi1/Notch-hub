import Foundation
import Observation

/// Reads a provider secret by account name. Injectable so tests never touch the
/// real Keychain.
typealias CreditCredentialReader = @Sendable (String) throws -> String?

private struct CreditFetchContext: Sendable {
    let teamID: String
    let probeEnabled: Bool
    let allowBillableProbe: Bool
    let fetchers: [CreditProvider: any CreditFetcher]
    let client: APIClient
    let credentialReader: CreditCredentialReader
}

/// Publishes one honest `ProviderResult` per provider for the AI Coding tab.
/// Network work runs off-main on the `APIClient` actor and per-provider fetchers;
/// observable mutation is `@MainActor`-isolated so SwiftUI updates are safe.
///
/// Credit/spend changes slowly, so it polls every 5 minutes (plus an immediate
/// refresh on `start()`, on settings-save, and on a manual refresh). The optional
/// billable Anthropic probe runs only on an explicit manual refresh and never
/// retries. On a failed fetch, the service keeps the last good value and marks it
/// stale rather than flickering to an error.
@MainActor
@Observable
final class CreditTrackerService {

    private(set) var results: [ProviderResult] =
        CreditProvider.allCases.map { ProviderResult(provider: $0, metric: .loading) }
    private(set) var isRefreshing = false

    @ObservationIgnored private let client = APIClient()
    @ObservationIgnored private let prefs: CreditPreferences
    @ObservationIgnored private let fetchers: [CreditProvider: any CreditFetcher]
    @ObservationIgnored private let credentialReader: CreditCredentialReader
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshAllowsBillableProbe: Bool?

    private static let pollIntervalNanos: UInt64 = 300 * 1_000_000_000

    init(
        prefs: CreditPreferences,
        fetchers: [CreditProvider: any CreditFetcher] = CreditTrackerService.defaultFetchers(),
        credentialReader: @escaping CreditCredentialReader = { account in
            try KeychainStore.read(account: account)
        }
    ) {
        self.prefs = prefs
        self.fetchers = fetchers
        self.credentialReader = credentialReader
    }

    nonisolated static func defaultFetchers() -> [CreditProvider: any CreditFetcher] {
        [
            .grok: GrokFetcher(),
            .anthropic: AnthropicFetcher(),
            .openai: OpenAIFetcher(),
            .google: GoogleFetcher()
        ]
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(allowBillableProbe: false)
                do {
                    try await Task.sleep(nanoseconds: Self.pollIntervalNanos)
                } catch is CancellationError {
                    break
                } catch {
                    NSLog(
                        "NotchHub credits: polling delay failed (%@)",
                        String(reflecting: type(of: error))
                    )
                    break
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fire-and-forget refresh for UI buttons / settings-save. Callers must opt
    /// in explicitly when the user has requested the billable Anthropic probe.
    func refreshNow(allowBillableProbe: Bool = false) {
        Task { await refresh(allowBillableProbe: allowBillableProbe) }
    }

    func refresh(allowBillableProbe: Bool = false) async {
        guard !isRefreshing else {
            pendingRefreshAllowsBillableProbe =
                (pendingRefreshAllowsBillableProbe ?? false) || allowBillableProbe
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var nextAllowsBillableProbe = allowBillableProbe
        while true {
            pendingRefreshAllowsBillableProbe = nil
            await performRefresh(allowBillableProbe: nextAllowsBillableProbe)
            guard let pendingRefreshAllowsBillableProbe else { return }
            nextAllowsBillableProbe = pendingRefreshAllowsBillableProbe
        }
    }

    private func performRefresh(allowBillableProbe: Bool) async {
        let current = results
        let context = CreditFetchContext(
            teamID: prefs.grokTeamID,
            probeEnabled: prefs.anthropicRateLimitProbe,
            allowBillableProbe: allowBillableProbe,
            fetchers: fetchers,
            client: client,
            credentialReader: credentialReader
        )

        let updated = await withTaskGroup(of: ProviderResult.self) { group -> [ProviderResult] in
            for existing in current {
                group.addTask {
                    await Self.fetchOne(existing, context: context)
                }
            }
            var out: [ProviderResult] = []
            for await result in group { out.append(result) }
            return out
        }

        // Re-impose canonical provider order (task completion order is arbitrary).
        results = CreditProvider.allCases.compactMap { provider in
            updated.first { $0.provider == provider }
        }
    }

    /// Resolve a single provider's metric, reading its key from the Keychain and
    /// preserving the last good value when a live fetch fails.
    private static func fetchOne(
        _ existing: ProviderResult,
        context: CreditFetchContext
    ) async -> ProviderResult {
        let provider = existing.provider
        guard let fetcher = context.fetchers[provider] else { return existing }

        guard provider.supportsAPIKeyMetric else {
            let metric = await fetcher.fetch(
                secret: "", teamID: nil, allowRateLimitProbe: false, client: context.client
            )
            return ProviderResult(provider: provider, metric: metric, lastUpdated: Date())
        }

        let storedSecret: String?
        do {
            storedSecret = try context.credentialReader(provider.rawValue)
        } catch {
            NSLog(
                "NotchHub credits: Keychain read failed for %@ (%@)",
                provider.rawValue,
                String(reflecting: type(of: error))
            )
            return resultAfterFailure(existing, error: .credentialStore)
        }

        guard let storedSecret else {
            return ProviderResult(
                provider: provider, metric: .unsupported(reason: "No key set"),
                lastUpdated: existing.lastUpdated
            )
        }
        guard let secret = CreditInputValidator.credential(storedSecret) else {
            NSLog("NotchHub credits: rejected invalid stored credential for %@", provider.rawValue)
            return resultAfterFailure(existing, error: .notConfigured)
        }

        if provider == .anthropic,
           context.probeEnabled,
           !context.allowBillableProbe,
           AnthropicFetcher.keyType(secret) == .standard {
            return deferredProbeResult(existing)
        }

        let metric = await fetcher.fetch(
            secret: secret,
            teamID: context.teamID,
            allowRateLimitProbe: context.probeEnabled && context.allowBillableProbe,
            client: context.client
        )

        // Graceful offline: keep the prior real value, just mark it stale.
        if case let .failure(error) = metric {
            return resultAfterFailure(existing, error: error)
        }
        return ProviderResult(provider: provider, metric: metric, lastUpdated: Date())
    }

    private static func deferredProbeResult(_ existing: ProviderResult) -> ProviderResult {
        if case .rateLimit = existing.metric {
            return ProviderResult(
                provider: existing.provider,
                metric: existing.metric,
                lastUpdated: existing.lastUpdated,
                staleReason: .manualProbeRequired
            )
        }
        return ProviderResult(
            provider: existing.provider,
            metric: .unsupported(reason: "Use manual refresh to probe"),
            lastUpdated: existing.lastUpdated
        )
    }

    private static func resultAfterFailure(
        _ existing: ProviderResult,
        error: ProviderMetricError
    ) -> ProviderResult {
        if existing.metric.isLiveValue {
            // Keep the last real number, but record *why* it is stale so the
            // tile can say so instead of showing an unexplained indicator.
            return ProviderResult(
                provider: existing.provider,
                metric: existing.metric,
                lastUpdated: existing.lastUpdated,
                staleReason: .fetchFailed(error)
            )
        }
        return ProviderResult(
            provider: existing.provider,
            metric: .failure(error),
            lastUpdated: existing.lastUpdated
        )
    }
}

private extension ProviderMetric {
    /// A previously-fetched real number worth keeping on screen during an outage.
    var isLiveValue: Bool {
        switch self {
        case .balance, .spend, .rateLimit: return true
        case .loading, .unsupported, .failure: return false
        }
    }
}
