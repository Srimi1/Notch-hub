import NotchHubSafeFeatures
import SwiftUI

struct CompactAgentsRow: View {
    let model: AppPresentationModel

    var body: some View {
        if let approval = model.pendingApproval {
            CompactApprovalRow(model: model, approval: approval)
        } else {
            HStack(spacing: 8) {
                ForEach(model.providers.prefix(2)) { provider in
                    CompactProviderQuotaCard(provider: provider)
                }
                CompactBridgeSessionCard(model: model)
                    .frame(minWidth: 180, maxWidth: 236)
            }
        }
    }
}

private struct CompactProviderQuotaCard: View {
    let provider: ProviderCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(provider.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                ConnectionDot(connection: provider.connection)
            }
            if provider.quotaWindows.isEmpty {
                disconnectedState
            } else {
                quotaValues
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 58, alignment: .topLeading)
        .background(
            CompactNotchTheme.subtleSurface,
            in: RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
        )
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.name), \(helpText)")
    }

    private var quotaValues: some View {
        HStack(spacing: 8) {
            ForEach(provider.quotaWindows.prefix(2)) { window in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(utilizationColor(window.usedPercent))
                    Text(quotaSubtitle(window))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CompactNotchTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var disconnectedState: some View {
        Text(provider.connection.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(provider.connection.requiresAttention ? .orange : CompactNotchTheme.secondaryText)
            .lineLimit(2)
    }

    private var helpText: String {
        if provider.quotaWindows.isEmpty {
            return provider.connection.label
        }
        return provider.quotaWindows.prefix(2).map {
            let usage = "\($0.label) \(Int($0.usedPercent.rounded())) percent used"
            guard let resetsAt = $0.resetsAt else { return usage }
            return "\(usage), resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
        }.joined(separator: ", ")
    }

    private func compactResetLabel(_ resetsAt: Date?) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds.isFinite, seconds > 0 else { return "now" }
        if seconds < 3_600 {
            return "\(Int(ceil(seconds / 60)))m"
        }
        if seconds < 172_800 {
            return "\(Int(ceil(seconds / 3_600)))h"
        }
        return "\(Int(ceil(seconds / 86_400)))d"
    }

    private func quotaSubtitle(_ window: QuotaWindowPresentation) -> String {
        guard let reset = compactResetLabel(window.resetsAt) else { return window.label }
        return "\(window.label) · ↻ \(reset)"
    }
}

private struct ConnectionDot: View {
    let connection: ProviderConnectionPresentation

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(connection.label)
    }

    private var color: Color {
        switch connection {
        case .connected: .green
        case .discovering, .disconnected: CompactNotchTheme.secondaryText
        case .unavailable, .failed: .orange
        }
    }
}
