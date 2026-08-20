import Foundation
import Observation

/// Non-secret configuration for the credit tracker, persisted in `UserDefaults`.
/// API keys are NEVER stored here — those live only in the Keychain
/// (`KeychainStore`). This holds the Grok team ID and the opt-in toggle for the
/// billable Anthropic rate-limit probe.
@MainActor
@Observable
final class CreditPreferences {

    private enum Key {
        static let grokTeamID = "credit.grok.teamID"
        static let anthropicProbe = "credit.anthropic.rateLimitProbe"
    }

    /// xAI team ID, needed for the prepaid-balance endpoint. Resolvable in console.x.ai.
    var grokTeamID: String {
        didSet { defaults.set(grokTeamID, forKey: Key.grokTeamID) }
    }

    /// When true, an explicit manual refresh may make one non-retried, billable
    /// `/v1/messages` probe to read per-minute rate-limit headers. Automatic
    /// five-minute refreshes never run the probe. Off by default.
    var anthropicRateLimitProbe: Bool {
        didSet { defaults.set(anthropicRateLimitProbe, forKey: Key.anthropicProbe) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grokTeamID = defaults.string(forKey: Key.grokTeamID) ?? ""
        anthropicRateLimitProbe = defaults.bool(forKey: Key.anthropicProbe)
    }
}
