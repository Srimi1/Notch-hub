import SwiftUI

/// Key-entry settings for the credit tracker. One row per provider with a
/// `SecureField` (keys go straight to the Keychain — never UserDefaults, never
/// read back into the field), plus the Grok team ID and the opt-in Anthropic
/// rate-limit probe. Hosted in the unified Settings window.
struct CreditSettingsView: View {
    @Bindable var prefs: CreditPreferences
    @Bindable var credit: CreditTrackerService

    @State private var drafts: [String: String] = [:]
    @State private var stored: [String: Bool] = [:]
    @State private var rowError: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(CreditProvider.allCases) { providerRow($0) }
                Divider()
                Toggle(isOn: $prefs.anthropicRateLimitProbe) {
                    Text("Anthropic: allow a manual rate-limit probe with a standard key")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Text(
                    "When enabled, clicking Refresh now makes exactly one tiny billable " +
                        "Messages request. Background refreshes never run this probe."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
                footer
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refreshStoredFlags)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("AI Credits").font(.system(size: 17, weight: .bold))
            Text("Stored securely in your macOS Keychain. Only Grok exposes a real balance.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func providerRow(_ provider: CreditProvider) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: provider.icon)
                    .foregroundStyle(CreditTileView.color(provider.accent))
                Text(provider.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(statusText(provider)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if provider.supportsAPIKeyMetric {
                keyEntry(provider)
                if provider == .grok {
                    TextField("xAI team ID", text: $prefs.grokTeamID)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
            }
            Text(provider.keyHint).font(.system(size: 10)).foregroundStyle(.secondary)
            if let disclosure = metricDisclosure(provider) {
                Text(disclosure).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let error = rowError[provider.rawValue] {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func keyEntry(_ provider: CreditProvider) -> some View {
        HStack(spacing: 6) {
            SecureField(placeholder(provider), text: binding(provider))
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Button("Save") { save(provider) }
                .disabled((drafts[provider.rawValue] ?? "").isEmpty)
            Button("Remove") { remove(provider) }
                .disabled(!(stored[provider.rawValue] ?? false))
        }
    }

    private var footer: some View {
        HStack {
            if credit.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button("Refresh now") { credit.refreshNow(allowBillableProbe: true) }
        }
    }

    // MARK: - State helpers

    private func binding(_ provider: CreditProvider) -> Binding<String> {
        Binding(
            get: { drafts[provider.rawValue] ?? "" },
            set: { drafts[provider.rawValue] = $0 }
        )
    }

    private func placeholder(_ provider: CreditProvider) -> String {
        (stored[provider.rawValue] ?? false) ? "•••••••• (saved — paste to replace)" : "Paste key"
    }

    private func statusText(_ provider: CreditProvider) -> String {
        guard let result = credit.results.first(where: { $0.provider == provider }) else { return "" }
        guard let stale = result.staleDisclosure() else { return Self.metricText(result.metric) }
        return "\(Self.metricText(result.metric)) · \(stale)"
    }

    /// The long-form caveat for a partial figure (currently Anthropic's cost
    /// report, which excludes Priority Tier usage).
    private func metricDisclosure(_ provider: CreditProvider) -> String? {
        credit.results.first { $0.provider == provider }?.metric.disclosure
    }

    private static func metricText(_ metric: ProviderMetric) -> String {
        switch metric {
        case let .balance(usd): return "Balance " + CreditTileView.money(usd)
        case let .spend(usd, _, scope):
            guard let suffix = scope.shortSuffix else { return "Spent " + CreditTileView.money(usd) }
            return "Spent \(CreditTileView.money(usd)) (\(suffix))"
        case .rateLimit: return "Rate limit"
        case let .unsupported(reason): return reason
        case let .failure(error): return error.userMessage
        case .loading: return "…"
        }
    }

    private func refreshStoredFlags() {
        for provider in CreditProvider.allCases where provider.supportsAPIKeyMetric {
            do {
                stored[provider.rawValue] = try KeychainStore.hasKey(account: provider.rawValue)
                rowError[provider.rawValue] = nil
            } catch {
                stored[provider.rawValue] = false
                rowError[provider.rawValue] = "Couldn't read Keychain status."
                logKeychainError(error, operation: "inspect", provider: provider)
            }
        }
    }

    private func save(_ provider: CreditProvider) {
        guard let value = CreditInputValidator.credential(drafts[provider.rawValue] ?? "") else {
            rowError[provider.rawValue] = "Use a valid API key without spaces or control characters."
            return
        }
        do {
            try KeychainStore.save(value, account: provider.rawValue)
            drafts[provider.rawValue] = ""
            stored[provider.rawValue] = true
            rowError[provider.rawValue] = nil
            credit.refreshNow()
        } catch {
            rowError[provider.rawValue] = "Couldn't save to Keychain."
            logKeychainError(error, operation: "save", provider: provider)
        }
    }

    private func remove(_ provider: CreditProvider) {
        do {
            try KeychainStore.delete(account: provider.rawValue)
            stored[provider.rawValue] = false
            rowError[provider.rawValue] = nil
            credit.refreshNow()
        } catch {
            rowError[provider.rawValue] = "Couldn't remove from Keychain."
            logKeychainError(error, operation: "remove", provider: provider)
        }
    }

    private func logKeychainError(
        _ error: Error,
        operation: String,
        provider: CreditProvider
    ) {
        NSLog(
            "NotchHub credits: Keychain %@ failed for %@ (%@)",
            operation,
            provider.rawValue,
            String(reflecting: type(of: error))
        )
    }
}
