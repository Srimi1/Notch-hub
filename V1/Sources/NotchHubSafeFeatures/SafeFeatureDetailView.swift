import SwiftUI

/// Reusable Store-safe feature surface shared by the direct and Lite editions.
public struct SafeFeatureDetailView: View {
    private let feature: SafeFeature
    private let workspace: SafeFeatureWorkspace

    public init(feature: SafeFeature, workspace: SafeFeatureWorkspace) {
        self.feature = feature
        self.workspace = workspace
    }

    public var body: some View {
        Group {
            switch feature {
            case .dashboard:
                DashboardFeatureView(model: workspace.dashboard)
            case .clipboard:
                ClipboardFeatureView(model: workspace.clipboard)
            case .focus:
                FocusFeatureView(model: workspace.focus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SafeIssueBanner: View {
    let message: String
    let actionTitle: String?
    let action: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct SafeEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.cyan)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
