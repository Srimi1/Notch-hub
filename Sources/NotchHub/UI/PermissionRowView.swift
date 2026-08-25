import SwiftUI

/// One permission, its state, and the single action that moves it forward.
///
/// Shared by the first-run window and the Settings section so the two never
/// drift into describing the same permission differently.
struct PermissionRowView: View {
    let permission: PermissionCenter.Permission
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .semibold))
                Text(permission.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailing: some View {
        if status == .granted {
            Label("On", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else {
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
    }

    private var buttonTitle: String {
        if !permission.isPromptable { return "Open Settings…" }
        switch status {
        case .denied: return "Open Settings…"
        case .granted: return "On"
        case .notDetermined, .unknown: return "Allow…"
        }
    }
}

extension PermissionStatus {
    /// Short label for the Settings list, where the row shows state as text.
    var shortLabel: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Not granted"
        case .notDetermined: "Not asked yet"
        case .unknown: "Unknown"
        }
    }
}
