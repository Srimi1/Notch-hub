import SwiftUI

struct SessionBridgeCard: View {
    let model: AppPresentationModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Terminal sessions").font(.subheadline.weight(.semibold))
                Text(model.sessionBridgeConnection.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            actionControl
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actionControl: some View {
        if model.sessionBridgeSubmissionInProgress || model.sessionBridgeConnection == .checking {
            ProgressView().controlSize(.small)
        } else if let action = model.sessionBridgeConnection.action {
            Button(action == .connect ? "Connect sessions…" : "Disconnect…") {
                Task { await model.performSessionBridgeAction() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var statusSymbol: String {
        switch model.sessionBridgeConnection {
        case .checking: "ellipsis.circle"
        case .disconnected: "terminal"
        case .connected: "checkmark.shield.fill"
        case .connectedWithCustomClaudeStatusLine: "checkmark.shield"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.sessionBridgeConnection {
        case .connected, .connectedWithCustomClaudeStatusLine: .green
        case .failed: .orange
        case .checking, .disconnected: .secondary
        }
    }
}

struct SessionList: View {
    let sessions: [AgentSessionPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions").font(.subheadline.weight(.semibold))
            if sessions.isEmpty {
                emptyState
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Label("No connected terminal sessions", systemImage: "terminal")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

private struct SessionRow: View {
    let session: AgentSessionPresentation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName).font(.subheadline.weight(.medium))
                Text(session.providerName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.status.label)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch session.status {
        case .running: "bolt.fill"
        case .waitingForApproval: "hand.raised.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .cyan
        case .waitingForApproval: .orange
        case .finished: .green
        case .failed: .red
        }
    }
}

struct ApprovalCard: View {
    let model: AppPresentationModel
    let approval: ApprovalCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            approvalHeader
            approvalContext
            if let preview = approval.preview {
                Text(preview)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            submissionMessage
            decisionButtons
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval requested by \(approval.providerName)")
    }

    private var approvalHeader: some View {
        HStack {
            Label("Approval requested", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Spacer()
            Text(approval.risk.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(approval.risk == .low ? Color.secondary : Color.orange)
        }
    }

    private var approvalContext: some View {
        HStack(spacing: 6) {
            Text(approval.providerName).fontWeight(.semibold)
            Text("•")
            Text(approval.projectName)
            Text("•")
            Text(approval.actionCategory)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var submissionMessage: some View {
        if case let .failed(message) = model.approvalSubmission {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var decisionButtons: some View {
        HStack {
            Text("One-time decision")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Deny", role: .destructive) {
                Task { await model.submitApproval(.deny) }
            }
            Button("Allow once") {
                Task { await model.submitApproval(.allowOnce) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .disabled(model.approvalSubmission == .submitting)
    }
}
