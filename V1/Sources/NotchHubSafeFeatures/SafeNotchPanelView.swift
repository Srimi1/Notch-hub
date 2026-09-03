import SwiftUI

public struct SafeNotchPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: SafeNotchPresentationModel
    private let onHover: @MainActor (Bool) -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        model: SafeNotchPresentationModel,
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
                SafeCompactSummary(model: model)
            } else {
                SafeNotchDetail(model: model, onDismiss: onDismiss)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 38)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SafeNotchBackground())
        .foregroundStyle(.white)
        .onHover(perform: onHover)
        .onAppear { model.workspace.start() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.tier)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub Lite")
    }
}

private struct SafeCompactSummary: View {
    let model: SafeNotchPresentationModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.cyan)
                Text("NotchHub Lite").font(.headline)
                Spacer()
                Text(model.workspace.dashboard.snapshot.sampledAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                CompactValue(
                    symbol: "cpu",
                    value: model.workspace.dashboard.snapshot.activeProcessorCount.formatted(),
                    label: "cores"
                )
                CompactValue(
                    symbol: "clipboard",
                    value: clipboardValue,
                    label: model.workspace.clipboard.isEnabled ? "clips" : "history"
                )
                CompactValue(
                    symbol: "timer",
                    value: model.workspace.focus.clockLabel,
                    label: model.workspace.focus.state.title.lowercased()
                )
            }
        }
    }

    private var clipboardValue: String {
        model.workspace.clipboard.isEnabled
            ? model.workspace.clipboard.entries.count.formatted()
            : "Off"
    }
}

private struct CompactValue: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.caption.weight(.semibold).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SafeNotchDetail: View {
    let model: SafeNotchPresentationModel
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 13) {
            detailHeader
            featureBar
            Divider().overlay(.white.opacity(0.12))
            SafeFeatureDetailView(feature: model.selectedFeature, workspace: model.workspace)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: model.selectedFeature.systemImage)
                .font(.title3)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedFeature.title).font(.headline)
                Text("NotchHub Lite").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close NotchHub")
        }
    }

    private var featureBar: some View {
        HStack(spacing: 6) {
            ForEach(SafeFeature.allCases) { feature in
                SafeFeatureButton(
                    feature: feature,
                    isSelected: model.selectedFeature == feature,
                    action: { model.select(feature) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchHub modules")
    }
}

private struct SafeFeatureButton: View {
    let feature: SafeFeature
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(feature.title, systemImage: feature.systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(
                    isSelected ? Color.cyan.opacity(0.22) : Color.white.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SafeNotchBackground: View {
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
