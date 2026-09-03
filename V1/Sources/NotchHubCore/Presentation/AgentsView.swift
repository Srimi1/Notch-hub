import SwiftUI

public struct NotchPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: AppPresentationModel
    private let onHover: @MainActor (Bool) -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        model: AppPresentationModel,
        onHover: @escaping @MainActor (Bool) -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.onHover = onHover
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if model.tier == .compact {
                CompactAgentsSummary(model: model)
            } else {
                NotchDetailView(model: model, onDismiss: onDismiss)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 38)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchBackground())
        .foregroundStyle(.white)
        .onHover(perform: onHover)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.tier)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.pendingApproval)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub")
    }
}

private struct NotchBackground: View {
    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: 0
        )
        .fill(.black.opacity(0.96))
        .overlay(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 0
            )
            .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct CompactAgentsSummary: View {
    let model: AppPresentationModel

    var body: some View {
        VStack(spacing: 12) {
            CompactHeader(model: model)
            if model.edition == .direct {
                compactProviders
                sessionSummary
            } else {
                liteSummary
            }
        }
    }

    private var compactProviders: some View {
        HStack(spacing: 12) {
            ForEach(model.providers) { provider in
                CompactProviderView(provider: provider)
            }
        }
    }

    private var sessionSummary: some View {
        HStack {
            Label("\(model.activeSessionCount) active", systemImage: "bolt.fill")
            Spacer()
            Text(model.hasAttention ? "Needs attention" : "Select for details")
                .foregroundStyle(model.hasAttention ? .orange : .secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var liteSummary: some View {
        HStack {
            Label("Dashboard, Clipboard & Focus", systemImage: "checkmark.shield")
            Spacer()
            Text("Store edition").foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct CompactHeader: View {
    let model: AppPresentationModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.edition == .direct ? "sparkles" : "shield.lefthalf.filled")
                .foregroundStyle(.cyan)
            Text(model.edition == .direct ? "AI Command Center" : "NotchHub Lite")
                .font(.headline)
            Spacer()
            StatusAttentionPill(model: model)
        }
    }
}

private struct StatusAttentionPill: View {
    let model: AppPresentationModel

    var body: some View {
        if model.hasAttention {
            Label("Attention", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption.weight(.semibold))
        } else if let utilization = model.highestUtilization {
            Text("\(Int(utilization.rounded()))% peak")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
        } else {
            Text("Checking providers")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

private struct CompactProviderView: View {
    let provider: ProviderCardPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.subheadline.weight(.semibold))
                compactState
            }
            Spacer(minLength: 4)
            UsageRing(value: provider.highestUtilization, diameter: 30)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var compactState: some View {
        if let utilization = provider.highestUtilization {
            Text("\(Int(utilization.rounded()))% used")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(provider.connection.label)
                .font(.caption)
                .foregroundStyle(provider.connection.requiresAttention ? .orange : .secondary)
        }
    }
}

private struct NotchDetailView: View {
    let model: AppPresentationModel
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 14) {
            DetailHeader(model: model, onDismiss: onDismiss)
            CapabilityBar(model: model)
            Divider().overlay(.white.opacity(0.12))
            selectedContent
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch model.selectedCapability {
        case .agents: AgentsDetail(model: model)
        case let capability: CapabilityFoundationView(capability: capability, edition: model.edition)
        }
    }
}

private struct DetailHeader: View {
    let model: AppPresentationModel
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.selectedCapability.systemImage)
                .font(.title3)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(detailTitle).font(.headline)
                Text(model.edition.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close NotchHub")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var detailTitle: String {
        model.selectedCapability == .agents ? "AI Command Center" : model.selectedCapability.title
    }
}

private struct CapabilityBar: View {
    let model: AppPresentationModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.edition.capabilities) { capability in
                CapabilityButton(
                    capability: capability,
                    selected: model.selectedCapability == capability,
                    action: { model.select(capability) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub modules")
    }
}

private struct CapabilityButton: View {
    let capability: AppCapability
    let selected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(capability.title, systemImage: capability.systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selected ? .cyan.opacity(0.2) : .white.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AgentsDetail: View {
    let model: AppPresentationModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ProviderGrid(providers: model.providers)
                SessionBridgeCard(model: model)
                if let approval = model.pendingApproval {
                    ApprovalCard(model: model, approval: approval)
                }
                SessionList(sessions: model.sessions)
            }
        }
        .scrollIndicators(.hidden)
    }
}
