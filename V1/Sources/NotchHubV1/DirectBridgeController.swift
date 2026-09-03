import AppKit
import Foundation
import NotchHubBridge
import NotchHubCore

@MainActor
final class DirectBridgeController {
    private enum ControllerError: Error {
        case unavailable
        case partialConfiguration
    }

    private let model: AppPresentationModel
    private let agentRuntime: DirectAgentRuntime
    private let server: BridgeUnixSocketServer
    private let helperInstaller: BridgeHelperInstaller
    private let configurationService: HookConfigurationService
    private let telemetry: LocalTelemetryConsole
    private lazy var eventCoordinator = makeEventCoordinator()

    private var serverTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    init(
        model: AppPresentationModel,
        agentRuntime: DirectAgentRuntime,
        server: BridgeUnixSocketServer = BridgeUnixSocketServer(),
        helperInstaller: BridgeHelperInstaller = BridgeHelperInstaller(),
        configurationService: HookConfigurationService = HookConfigurationService(),
        telemetry: LocalTelemetryConsole = LocalTelemetryConsole()
    ) {
        self.model = model
        self.agentRuntime = agentRuntime
        self.server = server
        self.helperInstaller = helperInstaller
        self.configurationService = configurationService
        self.telemetry = telemetry
    }

    func start() {
        guard serverTask == nil else { return }
        installModelHandlers()
        let server = server
        let coordinator = eventCoordinator
        serverTask = Task { [weak self] in
            do {
                try await Self.prepareKeychainSecret()
                try await server.start()
                await self?.refreshConnectionPresentation()
                try await server.serve { envelope in
                    await coordinator.handle(envelope)
                }
            } catch is CancellationError {
                return
            } catch let error as BridgeTransportError where error == .cancelled {
                return
            } catch {
                await self?.recordServerFailure()
            }
        }
    }

    func stop() {
        model.setApprovalHandler(nil)
        model.setSessionBridgeHandler(nil)
        serverTask?.cancel()
        serverTask = nil
        cleanupTask?.cancel()
        let server = server
        let coordinator = eventCoordinator
        cleanupTask = Task {
            await server.stop()
            await coordinator.stop()
        }
    }

    private func installModelHandlers() {
        let coordinator = eventCoordinator
        model.setApprovalHandler { identifier, decision in
            try await coordinator.respond(to: identifier, decision: decision)
        }
        model.setSessionBridgeHandler { [weak self] action in
            guard let self else { throw ControllerError.unavailable }
            return try await self.perform(action)
        }
    }

    private func makeEventCoordinator() -> BridgeAgentEventCoordinator {
        let model = model
        let runtime = agentRuntime
        let telemetry = telemetry
        return BridgeAgentEventCoordinator(
            stateHandler: { [weak model] snapshot in
                guard let model else { return }
                model.replaceSessions(snapshot.sessions)
                if let approval = snapshot.pendingApproval {
                    if model.pendingApproval?.id != approval.id {
                        model.presentApproval(approval)
                    }
                } else if model.pendingApproval != nil {
                    model.dismissApproval()
                }
            },
            claudeStatusHandler: { [weak model, runtime] event in
                let state = await runtime.ingestClaudeStatusLine(event)
                await MainActor.run {
                    model?.apply(
                        provider: state.provider,
                        snapshot: state.usageSnapshot,
                        connection: state.connectionState
                    )
                }
            },
            diagnosticHandler: { [weak model, telemetry] _ in
                await telemetry.record(
                    severity: .warning,
                    category: "bridge",
                    code: "event-rejected",
                    summary: "A sanitized bridge event failed domain validation."
                )
                await MainActor.run {
                    model?.setSessionBridgeConnection(
                        .failed("A session event was rejected; provider prompts remain active.")
                    )
                }
            }
        )
    }

    private static func prepareKeychainSecret() async throws {
        try await Task.detached {
            _ = try KeychainBridgeSecretStore().loadSecret()
        }.value
    }

    private func refreshConnectionPresentation() async {
        do {
            let previews = try await connectionPreviews()
            let allUnchanged = previews.allSatisfy { $0.diff.change == .unchanged }
            let helperExists = FileManager.default.isExecutableFile(atPath: helperInstaller.installedHelperURL.path)
            let state = allUnchanged && helperExists
                ? connectedState(fromDiffs: previews.map(\.diff))
                : SessionBridgeConnectionPresentation.disconnected
            await discard(previews)
            model.setSessionBridgeConnection(state)
        } catch {
            await recordConfigurationFailure(code: "inspect-failed")
        }
    }

    private func recordServerFailure() async {
        await telemetry.record(
            severity: .error,
            category: "bridge",
            code: "server-unavailable",
            summary: "The local authenticated bridge could not start."
        )
        model.setSessionBridgeConnection(
            .failed("Secure session bridge unavailable; provider prompts remain active.")
        )
    }
}

private extension DirectBridgeController {
    func perform(_ action: SessionBridgeAction) async throws -> SessionBridgeConnectionPresentation {
        switch action {
        case .connect:
            return try await connectSessions()
        case .disconnect:
            return try await disconnectSessions()
        }
    }

    func connectSessions() async throws -> SessionBridgeConnectionPresentation {
        let previews = try await connectionPreviews()
        guard presentConsent(for: previews, action: .connect) else {
            await discard(previews)
            return model.sessionBridgeConnection
        }

        do {
            _ = try await helperInstaller.install()
            let results = try await applyWithRollback(previews, operation: .connect)
            return connectedState(fromDiffs: results.map(\.diff))
        } catch {
            await discard(previews)
            await recordConfigurationFailure(code: "connect-failed")
            throw error
        }
    }

    func disconnectSessions() async throws -> SessionBridgeConnectionPresentation {
        let previews = try await disconnectionPreviews()
        guard presentConsent(for: previews, action: .disconnect) else {
            await discard(previews)
            return model.sessionBridgeConnection
        }

        do {
            _ = try await applyWithRollback(previews, operation: .disconnect)
            return .disconnected
        } catch {
            await discard(previews)
            await recordConfigurationFailure(code: "disconnect-failed")
            throw error
        }
    }

    func connectionPreviews() async throws -> [HookConfigurationConsentPreview] {
        let bridgePath = helperInstaller.installedHelperURL.path
        let codex = try await configurationService.previewConnection(
            provider: .codex,
            bridgeExecutablePath: bridgePath
        )
        do {
            let claude = try await configurationService.previewConnection(
                provider: .claude,
                bridgeExecutablePath: bridgePath
            )
            return [codex, claude]
        } catch {
            await configurationService.discard(codex)
            throw error
        }
    }

    func disconnectionPreviews() async throws -> [HookConfigurationConsentPreview] {
        let codex = try await configurationService.previewDisconnection(provider: .codex)
        do {
            let claude = try await configurationService.previewDisconnection(provider: .claude)
            return [codex, claude]
        } catch {
            await configurationService.discard(codex)
            throw error
        }
    }

    func applyWithRollback(
        _ previews: [HookConfigurationConsentPreview],
        operation: HookConfigurationOperation
    ) async throws -> [HookConfigurationApplicationResult] {
        var results: [HookConfigurationApplicationResult] = []
        do {
            for preview in previews {
                results.append(try await configurationService.apply(preview))
            }
            return results
        } catch {
            let originalError = error
            do {
                try await rollback(results, operation: operation)
            } catch {
                await recordConfigurationFailure(code: "rollback-failed")
                throw ControllerError.partialConfiguration
            }
            throw originalError
        }
    }

    func rollback(
        _ results: [HookConfigurationApplicationResult],
        operation: HookConfigurationOperation
    ) async throws {
        for result in results.reversed() where result.wroteConfiguration {
            let provider = result.diff.provider
            let rollbackPreview: HookConfigurationConsentPreview = switch operation {
            case .connect:
                try await configurationService.previewDisconnection(provider: provider)
            case .disconnect:
                try await configurationService.previewConnection(
                    provider: provider,
                    bridgeExecutablePath: helperInstaller.installedHelperURL.path
                )
            }
            _ = try await configurationService.apply(rollbackPreview)
        }
    }

    func discard(_ previews: [HookConfigurationConsentPreview]) async {
        for preview in previews {
            await configurationService.discard(preview)
        }
    }

    func presentConsent(
        for previews: [HookConfigurationConsentPreview],
        action: SessionBridgeAction
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = action == .connect ? "Connect terminal sessions?" : "Disconnect terminal sessions?"
        alert.informativeText = consentSummary(previews, action: action)
        alert.addButton(withTitle: action == .connect ? "Connect" : "Disconnect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func consentSummary(
        _ previews: [HookConfigurationConsentPreview],
        action: SessionBridgeAction
    ) -> String {
        let verb = action == .connect ? "add" : "remove"
        let lines = previews.map { preview in
            let provider = preview.diff.provider.rawValue.capitalized
            let path = preview.diff.provider == .codex ? "~/.codex/hooks.json" : "~/.claude/settings.json"
            return "• \(provider): \(verb) only NotchHub-owned entries in \(path)"
        }
        let compatibility = previews.contains {
            $0.diff.compatibility == .customClaudeStatusLinePreserved
        } ? "\n\nYour existing Claude status line will be preserved; Claude quota cannot be shown through it." : ""
        return lines.joined(separator: "\n")
            + "\n\nExisting settings and provider deny policies remain authoritative."
            + compatibility
    }

    func connectedState(
        fromDiffs diffs: [HookConfigurationDiff]
    ) -> SessionBridgeConnectionPresentation {
        diffs.contains { $0.compatibility == .customClaudeStatusLinePreserved }
            ? .connectedWithCustomClaudeStatusLine
            : .connected
    }

    func recordConfigurationFailure(code: String) async {
        await telemetry.record(
            severity: .error,
            category: "hooks",
            code: code,
            summary: "Session configuration failed without changing provider authority."
        )
    }
}
