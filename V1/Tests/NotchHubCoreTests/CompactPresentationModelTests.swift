import Foundation
import Testing
@testable import NotchHubCore

@MainActor
@Suite("Compact presentation updates")
struct CompactPresentationModelTests {
    @Test("Incremental provider updates preserve canonical order and refresh compact wings")
    func incrementalProviderUpdatesPreserveOrder() {
        let model = AppPresentationModel(edition: .direct)
        var layoutChanges = 0
        model.setLayoutChangeHandler { layoutChanges += 1 }

        model.apply(provider: .claude, snapshot: nil, connection: .notDetected)
        model.apply(provider: .codex, snapshot: nil, connection: .notDetected)

        #expect(model.providers.map(\.id) == ["codex", "claude"])
        #expect(layoutChanges == 2)

        model.showDetail()
        model.apply(provider: .claude, snapshot: nil, connection: .notDetected)
        #expect(layoutChanges == 3)
    }

    @Test("Compact session activity requests a wing layout refresh")
    func compactSessionActivityRefreshesLayout() {
        let model = AppPresentationModel(edition: .direct)
        var layoutChanges = 0
        model.setLayoutChangeHandler { layoutChanges += 1 }

        model.replaceSessions([session()])
        #expect(layoutChanges == 1)

        model.showDetail()
        model.replaceSessions([AgentSessionPresentation]())
        #expect(layoutChanges == 2)
    }

    @Test("Approval replaces the detail row and dismissal keeps the ribbon shallow")
    func approvalPresentationUsesFixedDetailTier() {
        let model = AppPresentationModel(edition: .direct)
        var layoutChanges = 0
        model.setLayoutChangeHandler { layoutChanges += 1 }
        model.select(.focus)
        model.showCompact()
        let changesBeforeApproval = layoutChanges

        model.presentApproval(approval())

        #expect(model.selectedCapability == .agents)
        #expect(model.tier == .detail)
        #expect(model.panelMetrics == .init(width: 860, height: 136))
        #expect(layoutChanges == changesBeforeApproval + 1)

        model.dismissApproval()
        #expect(model.tier == .detail)
        #expect(layoutChanges == changesBeforeApproval + 2)
    }

    private func session() -> AgentSessionPresentation {
        AgentSessionPresentation(
            id: "running",
            providerName: "Codex",
            projectName: "NotchHub",
            status: .running,
            updatedAt: .now
        )
    }

    private func approval() -> ApprovalCardPresentation {
        ApprovalCardPresentation(
            id: "approval",
            providerName: "Codex",
            projectName: "NotchHub",
            actionCategory: "Command",
            preview: "swift test",
            risk: .elevated,
            expiresAt: .distantFuture
        )
    }
}
