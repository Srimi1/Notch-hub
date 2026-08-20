import Foundation

/// The AI-coding API providers NotchHub can track credit/spend for.
///
/// Each provider exposes a *different* honest metric depending on what its API
/// actually allows (see `ProviderMetric`): only Grok has a real prepaid-balance
/// endpoint; Anthropic/OpenAI expose spend (with an admin key); Google has no
/// API-key balance concept at all. The UI never fabricates a missing value.
enum CreditProvider: String, CaseIterable, Identifiable, Sendable {
    case grok
    case anthropic
    case openai
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grok: "Grok (xAI)"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI / Codex"
        case .google: "Google / Gemini"
        }
    }

    /// SF Symbol for the tile icon.
    var icon: String {
        switch self {
        case .grok: "bolt.horizontal.fill"
        case .anthropic: "brain"
        case .openai: "curlybraces"
        case .google: "sparkle"
        }
    }

    /// UI-agnostic accent (mapped to a concrete `Color` in the UI layer so this
    /// Core type stays SwiftUI-free and unit-testable).
    var accent: AccentToken {
        switch self {
        case .grok: .yellow
        case .anthropic: .orange
        case .openai: .cyan
        case .google: .blue
        }
    }

    /// One-line hint shown under the settings field for this provider.
    var keyHint: String {
        switch self {
        case .grok: "Management key from console.x.ai (not your standard API key)"
        case .anthropic: "sk-ant-admin… → spend · standard sk-ant-… → not supported"
        case .openai: "Admin key → spend this month (otherwise not supported)"
        case .google: "No balance available via API key"
        }
    }

    /// Whether *any* live metric can be fetched with a key. Google is `false`
    /// (postpaid Cloud Billing needs OAuth, not an API key) so its tile is an
    /// honest placeholder rather than a perpetual error.
    var supportsAPIKeyMetric: Bool { self != .google }
}

/// UI-agnostic accent token. The UI layer maps it to a concrete `Color`; keeping
/// it here means `ProviderMetric.swift` needs no SwiftUI import.
enum AccentToken: Sendable {
    case yellow, orange, cyan, blue, purple, gray
}

/// The billing window a spend figure covers.
enum BillingPeriod: Sendable, Equatable {
    case month
    var label: String { "this month" }
}

/// What a spend figure does and does not include.
///
/// Anthropic's Admin cost report deliberately omits Priority Tier usage — that
/// capacity is billed under a different model and is only visible through the
/// usage endpoint. A number sourced from the cost report therefore must not be
/// presented as a complete account total.
enum SpendScope: Sendable, Equatable {
    case complete
    case excludingPriorityTier

    /// Compact qualifier appended to the tile's label. `nil` means "complete".
    var shortSuffix: String? {
        switch self {
        case .complete: nil
        case .excludingPriorityTier: "excl. Priority Tier"
        }
    }

    /// Full sentence for tooltips and settings, where there is room to be exact.
    var disclosure: String? {
        switch self {
        case .complete: nil
        case .excludingPriorityTier:
            "Anthropic's cost report excludes Priority Tier usage, so this is not a complete account total."
        }
    }
}

/// Typed, honest failure modes. `userMessage` is tile-safe and never carries a key.
enum ProviderMetricError: Error, Equatable, Sendable {
    case offline
    case transport
    case unauthorized
    case forbidden(String)
    case missingTeamID
    case invalidTeamID
    case notConfigured
    case credentialStore
    case badResponse(status: Int)
    case malformedResponse
    case incompleteReport
    case unsafeRedirect

    var userMessage: String {
        switch self {
        case .offline: "Offline"
        case .transport: "Connection failed"
        case .unauthorized: "Invalid key"
        case let .forbidden(why): why
        case .missingTeamID: "Set team ID in settings"
        case .invalidTeamID: "Invalid team ID"
        case .notConfigured: "Unrecognized key"
        case .credentialStore: "Keychain unavailable"
        case let .badResponse(status): "Error \(status)"
        case .malformedResponse: "Unexpected response"
        case .incompleteReport: "Incomplete report"
        case .unsafeRedirect: "Blocked unsafe redirect"
        }
    }
}

/// Rejects control characters, whitespace, path separators, and unbounded input
/// before user-supplied provider settings reach the Keychain or a request URL.
enum CreditInputValidator {
    static func credential(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({ (0x21 ... 0x7E).contains($0.value) })
        else {
            return nil
        }
        return value
    }

    static func teamID(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }

        let isAllowed: (Unicode.Scalar) -> Bool = { scalar in
            switch scalar.value {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2D, 0x5F: true
            default: false
            }
        }
        guard value.unicodeScalars.allSatisfy(isAllowed) else { return nil }
        return value
    }
}

/// The honest, labeled metric union. A tile renders exactly one case — there is
/// no path that fabricates a number: a missing key yields `.unsupported`, never
/// a fake `$0` balance.
enum ProviderMetric: Sendable, Equatable {
    case loading
    case balance(usd: Double)
    case spend(usd: Double, period: BillingPeriod, scope: SpendScope)
    case rateLimit(remainingRequests: Int?, remainingTokens: Int?)
    case unsupported(reason: String)
    case failure(ProviderMetricError)

    /// Short label shown beneath the value in the tile.
    var label: String {
        switch self {
        case .loading: return "Loading…"
        case .balance: return "Balance"
        case let .spend(_, period, scope):
            guard let suffix = scope.shortSuffix else { return "Spent \(period.label)" }
            return "Spent \(period.label) · \(suffix)"
        case .rateLimit: return "Per-min remaining"
        case .unsupported: return "Not supported"
        case .failure: return "Error"
        }
    }

    /// Long-form caveat for tooltips and settings, when the number is partial.
    var disclosure: String? {
        guard case let .spend(_, _, scope) = self else { return nil }
        return scope.disclosure
    }
}

/// Why a previously-good value is still on screen instead of a fresh one.
enum StaleReason: Sendable, Equatable {
    /// The last live fetch failed; the prior number is retained rather than
    /// flickering to an error.
    case fetchFailed(ProviderMetricError)
    /// A billable probe is deliberately not run on the background poll.
    case manualProbeRequired

    var message: String {
        switch self {
        case let .fetchFailed(error): error.userMessage
        case .manualProbeRequired: "Manual refresh needed"
        }
    }
}

/// One published row per provider that the AI Coding tab binds to.
///
/// A retained-but-stale financial number is never shown bare: `staleDisclosure`
/// spells out *why* it is stale and *how old* it is, so a figure that is hours
/// out of date cannot be mistaken for a live balance.
struct ProviderResult: Sendable, Equatable, Identifiable {
    let provider: CreditProvider
    var metric: ProviderMetric
    var lastUpdated: Date?
    var staleReason: StaleReason?

    var id: String { provider.rawValue }
    var isStale: Bool { staleReason != nil }

    init(
        provider: CreditProvider,
        metric: ProviderMetric = .loading,
        lastUpdated: Date? = nil,
        staleReason: StaleReason? = nil
    ) {
        self.provider = provider
        self.metric = metric
        self.lastUpdated = lastUpdated
        self.staleReason = staleReason
    }

    /// e.g. "Offline · 12m old". `nil` when the value is live.
    func staleDisclosure(now: Date = Date()) -> String? {
        guard let staleReason else { return nil }
        guard let lastUpdated else { return staleReason.message }
        return "\(staleReason.message) · \(Self.age(from: lastUpdated, to: now)) old"
    }

    /// Coarse, non-alarming age string. Deliberately rounds down.
    static func age(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
