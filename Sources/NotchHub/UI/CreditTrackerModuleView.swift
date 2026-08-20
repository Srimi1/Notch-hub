import SwiftUI

/// The AI Coding tab body: live agent status + Allow/Deny approvals and recent
/// messages (from `AICodingService`), alongside the adaptive API-key credit/spend
/// tiles (from `CreditTrackerService`). Replaces the old local-file quota tiles.
struct CreditTrackerModuleView: View {
    @ObservedObject var aiCoding: AICodingService
    @Bindable var credit: CreditTrackerService

    var body: some View {
        if let approval = aiCoding.pendingApproval {
            approvalView(approval)
        } else {
            statusAndCreditsView
        }
    }

    private var statusAndCreditsView: some View {
        HStack(spacing: 12) {
            statusTile
                .frame(width: 120, alignment: .leading)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(credit.results) { CreditTileView(result: $0) }
                    if !aiCoding.recentLogs.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.12))
                            .frame(maxHeight: 28)
                        ForEach(aiCoding.recentLogs) { logCard($0) }
                    }
                }
            }
        }
    }

    private var statusTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.5), radius: 2)
                Text(aiCoding.status.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(statusColor)
            }
            if aiCoding.status == .idle {
                Text("All agents inactive")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            } else {
                Text("\(aiCoding.activeAgent) · \(aiCoding.activeProject)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }

    private func logCard(_ log: AICodingService.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(log.agent)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(RelativeTime.ago(log.timestamp))
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(log.project)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.purple.opacity(0.8))
                .lineLimit(1)
            Text(log.message)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(4)
        .frame(width: 110, height: 38, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
    }

    private func approvalView(_ log: AICodingService.LogEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .shadow(color: .orange.opacity(0.5), radius: 2)
                    Text("PENDING APPROVAL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Text("\(log.agent) needs attention in \(log.project)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let approvalError = aiCoding.approvalError {
                    Text(approvalError)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                approvalButton(title: "Deny", filled: false) { aiCoding.handleApproval(approved: false) }
                approvalButton(title: "Allow", filled: true) { aiCoding.handleApproval(approved: true) }
            }
        }
        .padding(.trailing, 4)
    }

    private func approvalButton(title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(filled ? .black : .white)
                .padding(.horizontal, filled ? 12 : 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Color.green : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch aiCoding.status {
        case .idle: .gray
        case .running: .green
        case .needsAttention: .orange
        case .completed: .purple
        }
    }
}
