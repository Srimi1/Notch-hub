import Foundation
import NotchHubBridge
import Security
import Testing
@testable import NotchHubCore

@MainActor
@Suite("App presentation")
struct PresentationModelTests {
    @Test("Direct edition starts truthfully disconnected")
    func directProductionStateHasNoMockUsage() {
        let model = AppPresentationModel(edition: .direct)

        #expect(model.selectedCapability == .agents)
        #expect(model.providers.count == 2)
        #expect(model.providers.allSatisfy { $0.quotaWindows.isEmpty })
        #expect(model.highestUtilization == nil)
        #expect(!model.hasAttention)
        #expect(model.media != nil)
        #expect(model.edition.capabilities == [.agents, .dashboard, .media, .clipboard, .focus])
        #expect(model.panelMetrics == .init(width: 190, height: 32))

        model.showDetail()
        #expect(model.panelMetrics == .init(width: 860, height: 136))

        model.presentApproval(approval())
        #expect(model.panelMetrics == .init(width: 860, height: 136))

        model.select(.media)
        #expect(model.selectedCapability == .media)
        #expect(model.tier == .detail)
    }

    @Test("Direct edition retains the injected sandbox-safe workspace")
    func directEditionUsesSafeWorkspace() {
        let workspace = AppPresentationModel(edition: .lite).safeFeatures
        let model = AppPresentationModel(edition: .direct, safeFeatures: workspace)

        #expect(model.safeFeatures === workspace)
        #expect(model.safeFeatures.focus.setDuration(minutes: 42))
        #expect(workspace.focus.selectedMinutes == 42)
    }

    @Test("Lite exposes only sandbox-safe capabilities")
    func liteCapabilitiesAreRestricted() {
        let model = AppPresentationModel(edition: .lite)

        #expect(model.selectedCapability == .dashboard)
        #expect(model.edition.capabilities == [.dashboard, .clipboard, .focus])
        #expect(!model.edition.capabilities.contains(.media))
        #expect(model.media == nil)
        #expect(model.providers.isEmpty)
        model.select(.agents)
        #expect(model.selectedCapability == .dashboard)
        model.select(.media)
        #expect(model.selectedCapability == .dashboard)
    }

    @Test("Combined meter uses the most constrained provider")
    func highestUtilizationWins() {
        let model = AppPresentationModel(edition: .direct)
        model.replaceProviders([
            provider(id: "claude", usedPercent: 86),
            provider(id: "codex", usedPercent: 41),
        ])

        #expect(model.highestUtilization == 86)
        #expect(model.providers.map(\.id) == ["codex", "claude"])
    }

    @Test("Session activity ignores finished work")
    func activeSessionCountIsConservative() {
        let model = AppPresentationModel(edition: .direct)
        model.replaceSessions([
            session(id: "running", status: .running, secondsAgo: 20),
            session(id: "approval", status: .waitingForApproval, secondsAgo: 10),
            session(id: "finished", status: .finished, secondsAgo: 5),
        ])

        #expect(model.activeSessionCount == 2)
        #expect(model.sessions.map(\.id) == ["finished", "approval", "running"])
    }

    @Test("Approval decisions submit at most once")
    func approvalDecisionIsOneTime() async {
        let recorder = ApprovalRecorder()
        let model = AppPresentationModel(edition: .direct) { identifier, decision in
            await recorder.record(identifier: identifier, decision: decision)
        }
        model.presentApproval(approval())

        await model.submitApproval(.allowOnce)
        await model.submitApproval(.deny)

        #expect(await recorder.values == [.init(identifier: "approval", decision: .allowOnce)])
        #expect(model.pendingApproval == nil)
        #expect(model.approvalSubmission == .idle)
    }

    @Test("Expired approval abstains without invoking provider")
    func expiredApprovalAbstains() async {
        let recorder = ApprovalRecorder()
        let model = AppPresentationModel(edition: .direct) { identifier, decision in
            await recorder.record(identifier: identifier, decision: decision)
        }
        model.presentApproval(approval(expiresAt: .distantPast))

        await model.submitApproval(.allowOnce)

        #expect(await recorder.values.isEmpty)
        #expect(model.pendingApproval == nil)
    }

    @Test("Missing approval transport never implies success")
    func missingApprovalTransportAbstains() async {
        let model = AppPresentationModel(edition: .direct)
        model.presentApproval(approval())

        await model.submitApproval(.allowOnce)

        #expect(model.pendingApproval != nil)
        #expect(model.approvalSubmission == .failed("No secure approval connection is available."))
    }

    @Test("Unknown core approvals always display as high risk")
    func unknownApprovalIsConservative() throws {
        let receivedAt = Date.now
        let request = try ApprovalRequest(
            id: "approval",
            provider: .codex,
            sessionID: "session",
            projectName: "NotchHub",
            actionCategory: .unknown,
            rawPreview: "untrusted detail",
            risk: .low,
            receivedAt: receivedAt,
            expiresAt: receivedAt.addingTimeInterval(ApprovalRequest.maximumLifetime)
        )

        let presentation = ApprovalCardPresentation(request)

        #expect(presentation.risk == .high)
        #expect(presentation.preview == "Unrecognized action")
    }

    @Test("Session connection actions are explicit and update compatibility state")
    func sessionConnectionAction() async {
        let recorder = SessionBridgeRecorder()
        let model = AppPresentationModel(edition: .direct)
        model.setSessionBridgeConnection(.disconnected)
        model.setSessionBridgeHandler { action in
            recorder.actions.append(action)
            return .connectedWithCustomClaudeStatusLine
        }

        await model.performSessionBridgeAction()

        #expect(recorder.actions == [.connect])
        #expect(model.sessionBridgeConnection == .connectedWithCustomClaudeStatusLine)
        #expect(!model.sessionBridgeSubmissionInProgress)
    }

    @Test("Session connection failure keeps provider-native prompts authoritative")
    func sessionConnectionFailure() async {
        let model = AppPresentationModel(edition: .direct)
        model.setSessionBridgeConnection(.disconnected)
        model.setSessionBridgeHandler { _ in throw ProviderError.hookConflict(provider: .codex) }

        await model.performSessionBridgeAction()

        #expect(
            model.sessionBridgeConnection
                == .failed("Session setup failed safely; provider prompts remain active.")
        )
    }

    @Test("Unavailable session bridge cannot configure provider hooks")
    func unavailableSessionBridgeHasNoAction() {
        let model = AppPresentationModel(edition: .direct)
        let failure = SessionBridgeConnectionPresentation.startupFailure(
            for: BridgeTransportError.keychainSharingUnavailable(status: errSecMissingEntitlement)
        )

        model.setSessionBridgeConnection(failure)

        #expect(
            failure
                == .unavailable("Session bridge unavailable in this build; provider prompts remain active.")
        )
        #expect(model.sessionBridgeConnection.action == nil)
    }

    @Test("Transient session bridge startup failure offers an explicit retry")
    func transientSessionBridgeStartupCanRetry() async {
        let recorder = SessionBridgeRecorder()
        let model = AppPresentationModel(edition: .direct)
        let failure = SessionBridgeConnectionPresentation.startupFailure(
            for: BridgeTransportError.socketPathConflict
        )
        model.setSessionBridgeConnection(failure)
        model.setSessionBridgeHandler { action in
            recorder.actions.append(action)
            return .checking
        }

        await model.performSessionBridgeAction()

        #expect(
            failure
                == .startupFailed(
                    "Session bridge could not start. Retry or restart NotchHub; provider prompts remain active."
                )
        )
        #expect(SessionBridgeAction.retryStartup.buttonLabel == "Retry bridge")
        #expect(recorder.actions == [.retryStartup])
        #expect(model.sessionBridgeConnection == .checking)
        #expect(!model.sessionBridgeSubmissionInProgress)
        #expect(
            SessionBridgeConnectionPresentation.startupFailure(
                for: BridgeTransportError.keychainSharingUnavailable(status: errSecNotAvailable)
            ).action == .retryStartup
        )
    }

    @Test("External labels and previews are bounded")
    func presentationStringsAreBounded() {
        let value = ApprovalCardPresentation(
            id: "approval",
            providerName: String(repeating: "p", count: 100),
            projectName: String(repeating: "x", count: 100),
            actionCategory: String(repeating: "a", count: 100),
            preview: String(repeating: "z", count: 400),
            risk: .high,
            expiresAt: .distantFuture
        )

        #expect(value.providerName.count == 32)
        #expect(value.projectName.count == 64)
        #expect(value.actionCategory.count == 48)
        #expect(value.preview?.count == 240)
    }

    private func provider(id: String, usedPercent: Double) -> ProviderCardPresentation {
        ProviderCardPresentation(
            id: id,
            name: id,
            symbol: "circle",
            connection: .connected,
            quotaWindows: [
                .init(id: "window", label: "Window", usedPercent: usedPercent, resetsAt: nil),
            ]
        )
    }

    private func session(
        id: String,
        status: SessionStatusPresentation,
        secondsAgo: TimeInterval
    ) -> AgentSessionPresentation {
        AgentSessionPresentation(
            id: id,
            providerName: "provider",
            projectName: "project",
            status: status,
            updatedAt: Date().addingTimeInterval(-secondsAgo)
        )
    }

    private func approval(expiresAt: Date = .distantFuture) -> ApprovalCardPresentation {
        ApprovalCardPresentation(
            id: "approval",
            providerName: "Codex",
            projectName: "NotchHub",
            actionCategory: "Command",
            preview: "swift test",
            risk: .elevated,
            expiresAt: expiresAt
        )
    }
}

@MainActor
private final class SessionBridgeRecorder {
    var actions: [SessionBridgeAction] = []
}

private actor ApprovalRecorder {
    struct Value: Sendable, Equatable {
        let identifier: String
        let decision: ApprovalDecision
    }

    private(set) var values: [Value] = []

    func record(identifier: String, decision: ApprovalDecision) {
        values.append(.init(identifier: identifier, decision: decision))
    }
}
