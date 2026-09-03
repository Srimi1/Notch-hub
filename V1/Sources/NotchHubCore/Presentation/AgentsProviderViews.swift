import Foundation
import SwiftUI

struct ProviderGrid: View {
    let providers: [ProviderCardPresentation]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(providers) { provider in
                ProviderQuotaCard(provider: provider)
            }
        }
    }
}

private struct ProviderQuotaCard: View {
    let provider: ProviderCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerHeader
            if provider.quotaWindows.isEmpty {
                disconnectedState
            } else {
                ForEach(provider.quotaWindows) { window in
                    QuotaWindowRow(window: window)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.name)
    }

    private var providerHeader: some View {
        HStack {
            Label(provider.name, systemImage: provider.symbol)
                .font(.subheadline.weight(.semibold))
            Spacer()
            ConnectionDot(connection: provider.connection)
        }
    }

    private var disconnectedState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.connection.label)
                .foregroundStyle(provider.connection.requiresAttention ? .orange : .secondary)
            Text(setupInstruction)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let setupURL {
                Link("Open official setup guide", destination: setupURL)
                    .font(.caption)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private var setupInstruction: String {
        switch provider.id {
        case ProviderID.codex.rawValue: "Install Codex, then run codex login in Terminal."
        case ProviderID.claude.rawValue: "Install Claude Code, then run claude and follow sign-in."
        default: "Install or sign in with the official CLI to show limits."
        }
    }

    private var setupURL: URL? {
        switch provider.id {
        case ProviderID.codex.rawValue: URL(string: "https://learn.chatgpt.com/docs/codex/cli")
        case ProviderID.claude.rawValue: URL(string: "https://code.claude.com/docs/en/setup")
        default: nil
        }
    }
}

private struct ConnectionDot: View {
    let connection: ProviderConnectionPresentation

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(connection.label)
    }

    private var color: Color {
        switch connection {
        case .connected: .green
        case .discovering, .disconnected: .secondary
        case .unavailable, .failed: .orange
        }
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaWindowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: window.usedPercent, total: 100)
                .tint(utilizationColor(window.usedPercent))
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
