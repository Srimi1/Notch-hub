import NotchHubSafeFeatures
import SwiftUI

struct CompactBridgeSessionCard: View {
    let model: AppPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
                Text(compactBridgeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CompactNotchTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                actionControl
            }
            sessionSummary
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 58, alignment: .topLeading)
        .background(
            CompactNotchTheme.subtleSurface,
            in: RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
        )
        .help(model.sessionBridgeConnection.label)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actionControl: some View {
        if model.sessionBridgeSubmissionInProgress || model.sessionBridgeConnection == .checking {
            ProgressView().controlSize(.mini)
        } else if let action = model.sessionBridgeConnection.action {
            Button(action.compactButtonLabel) {
                Task { await model.performSessionBridgeAction() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(CompactNotchTheme.hoverSurface, in: Capsule())
        }
    }

    private var sessionSummary: some View {
        HStack(spacing: 5) {
            Image(systemName: model.activeSessionCount > 0 ? "bolt.fill" : "terminal")
                .foregroundStyle(model.activeSessionCount > 0 ? .cyan : CompactNotchTheme.secondaryText)
                .frame(width: 14)
            Text(sessionText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CompactNotchTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var sessionText: String {
        guard model.activeSessionCount > 0 else { return "No active sessions" }
        guard let session = model.sessions.first(where: {
            $0.status == .running || $0.status == .waitingForApproval
        }) else {
            return "\(model.activeSessionCount) active"
        }
        return "\(model.activeSessionCount) active · \(session.projectName)"
    }

    private var statusSymbol: String {
        switch model.sessionBridgeConnection {
        case .checking: "ellipsis.circle"
        case .disconnected: "terminal"
        case .connected: "checkmark.shield.fill"
        case .connectedWithCustomClaudeStatusLine: "checkmark.shield"
        case .unavailable: "lock.slash.fill"
        case .startupFailed: "arrow.clockwise.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var compactBridgeLabel: String {
        switch model.sessionBridgeConnection {
        case .checking: "Checking session bridge"
        case .disconnected: "Sessions disconnected"
        case .connected: "Sessions connected"
        case .connectedWithCustomClaudeStatusLine: "Connected · Claude status preserved"
        case .unavailable: "Session bridge unavailable"
        case .startupFailed: "Session bridge failed to start"
        case .failed: "Session bridge needs attention"
        }
    }

    private var statusColor: Color {
        switch model.sessionBridgeConnection {
        case .connected, .connectedWithCustomClaudeStatusLine: .green
        case .unavailable, .startupFailed, .failed: .orange
        case .checking, .disconnected: CompactNotchTheme.secondaryText
        }
    }
}

struct CompactApprovalRow: View {
    let model: AppPresentationModel
    let approval: ApprovalCardPresentation

    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(CompactNotchTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 8))
            approvalText
            Spacer(minLength: 6)
            Text(approval.risk.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(approval.risk == .low ? CompactNotchTheme.secondaryText : .orange)
                .lineLimit(1)
            CompactApprovalButton(title: "Deny", action: { submit(.deny) })
            CompactApprovalButton(title: "Review", prominent: true) { showsDetails = true }
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    CompactApprovalDetails(
                        model: model,
                        approval: approval,
                        isPresented: $showsDetails
                    )
                }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 62)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CompactNotchTheme.cardRadius)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        )
        .disabled(model.approvalSubmission == .submitting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval requested by \(approval.providerName)")
    }

    private var approvalText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(approval.providerName) · \(approval.projectName) · \(approval.actionCategory)")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(detailText)
                .font(.system(size: 10, weight: .semibold).monospaced())
                .foregroundStyle(CompactNotchTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private var detailText: String {
        if case let .failed(message) = model.approvalSubmission {
            return message
        }
        return approval.preview ?? "Open Review before allowing this one-time action."
    }

    private func submit(_ decision: ApprovalDecision) {
        Task { await model.submitApproval(decision) }
    }
}

private struct CompactApprovalDetails: View {
    let model: AppPresentationModel
    let approval: ApprovalCardPresentation
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review approval", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            detailLabels
            Divider()
            ScrollView {
                Text(fullDetail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            if case let .failed(message) = model.approvalSubmission {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            actionRow
        }
        .padding(16)
        .frame(width: 400)
    }

    private var detailLabels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(approval.providerName) · \(approval.projectName)")
                .font(.subheadline.weight(.semibold))
            Text("\(approval.actionCategory) · \(approval.risk.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fullDetail: String {
        approval.preview ?? "No additional action detail was supplied. Deny if this was unexpected."
    }

    private var actionRow: some View {
        HStack {
            Button("Cancel") { isPresented = false }
            Spacer()
            Button("Deny") { submit(.deny) }
                .buttonStyle(.bordered)
            Button("Allow once") { submit(.allowOnce) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .disabled(model.approvalSubmission == .submitting)
    }

    private func submit(_ decision: ApprovalDecision) {
        Task {
            await model.submitApproval(decision)
            if model.pendingApproval == nil {
                isPresented = false
            }
        }
    }
}

private struct CompactApprovalButton: View {
    let title: String
    var prominent = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(prominent ? Color.orange : CompactNotchTheme.hoverSurface, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension SessionBridgeAction {
    var compactButtonLabel: String {
        switch self {
        case .connect: "Connect"
        case .disconnect: "Off"
        case .retryStartup: "Retry"
        }
    }
}
