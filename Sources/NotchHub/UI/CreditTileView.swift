import SwiftUI

/// One honest credit/spend tile, rendered strictly from a `ProviderResult`.
/// Shows the labeled metric the provider's key actually unlocks (Balance / Spend /
/// rate limit / Not supported / Error) and never a fabricated number.
struct CreditTileView: View {
    let result: ProviderResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Text(valueText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(footnote)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(footnoteColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(5)
        .frame(width: 120, height: 38, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: borderColor == .clear ? 0 : 1)
        )
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    /// A retained-but-stale number always says why it is stale and how old it
    /// is; an orange indicator alone is not informed consent for a figure the
    /// user may act on financially.
    private var footnote: String {
        result.staleDisclosure() ?? result.metric.label
    }

    private var footnoteColor: Color {
        result.isStale ? .orange.opacity(0.9) : .white.opacity(0.45)
    }

    private var tooltip: String {
        var lines = ["\(result.provider.displayName): \(valueText) — \(result.metric.label)"]
        if let stale = result.staleDisclosure() {
            lines.append("Not refreshed: \(stale).")
        }
        if let disclosure = result.metric.disclosure {
            lines.append(disclosure)
        }
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: result.provider.icon)
                .font(.system(size: 8))
                .foregroundStyle(accentColor)
            Text(result.provider.displayName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
            Circle()
                .fill(statusDot)
                .frame(width: 5, height: 5)
                .shadow(color: statusDot.opacity(0.5), radius: 1)
        }
    }

    private var valueText: String {
        switch result.metric {
        case .loading: "…"
        case let .balance(usd): Self.money(usd)
        case let .spend(usd, _, _): Self.money(usd)
        case let .rateLimit(req, tok): Self.rateText(req, tok)
        case let .unsupported(reason): reason
        case let .failure(error): error.userMessage
        }
    }

    static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    static func rateText(_ req: Int?, _ tok: Int?) -> String {
        let requests = req.map(String.init) ?? "—"
        guard let tok else { return "\(requests) req" }
        return "\(requests) req · \(tok / 1000)k tok"
    }

    private var statusDot: Color {
        if result.isStale { return .orange }
        switch result.metric {
        case .loading: return .gray
        case .balance, .spend, .rateLimit: return .green
        case .unsupported: return .gray.opacity(0.5)
        case .failure: return .red
        }
    }

    private var borderColor: Color {
        if result.isStale { return .orange.opacity(0.35) }
        if case .failure = result.metric { return .red.opacity(0.25) }
        return .clear
    }

    private var accentColor: Color { Self.color(result.provider.accent) }

    static func color(_ token: AccentToken) -> Color {
        switch token {
        case .yellow: .yellow
        case .orange: .orange
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
