import AppKit
import NotchHubCore
import NotchHubMedia
import Observation
import UniformTypeIdentifiers

@MainActor
final class NotchHubV1ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let shellController: NotchHubApplicationController
    private let updaterController: DirectUpdaterController
    private let notificationObserver: PresentationNotificationObserver
    private let agentRuntime: DirectAgentRuntime
    private let bridgeController: DirectBridgeController
    private let mediaRuntime: MediaRuntimeController
    private let telemetry: LocalTelemetryConsole
    private var agentRuntimeTask: Task<Void, Never>?

    override init() {
        let telemetry = LocalTelemetryConsole()
        let mediaModel = MediaPresentationModel()
        let shellController = NotchHubApplicationController(edition: .direct, media: mediaModel)
        let agentRuntime = DirectAgentRuntime(
            telemetry: LocalDirectAgentRuntimeTelemetry(console: telemetry)
        )
        self.shellController = shellController
        self.updaterController = DirectUpdaterController()
        self.notificationObserver = PresentationNotificationObserver(model: shellController.model)
        self.agentRuntime = agentRuntime
        self.telemetry = telemetry
        self.mediaRuntime = MediaRuntimeController(model: mediaModel) { diagnostic in
            let severity: TelemetrySeverity = switch diagnostic.severity {
            case .info: .info
            case .warning: .warning
            case .error: .error
            }
            Task {
                await telemetry.record(
                    severity: severity,
                    category: "media",
                    code: diagnostic.code,
                    summary: diagnostic.summary
                )
            }
        }
        self.bridgeController = DirectBridgeController(
            model: shellController.model,
            agentRuntime: agentRuntime,
            telemetry: telemetry
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shellController.applicationDidFinishLaunching(notification)
        updaterController.startIfConfigured()
        installApplicationMenu()
        notificationObserver.start()
        migrateLegacyPreferencesForOfficialBuild()
        bridgeController.start()
        mediaRuntime.start()
        startAgentRuntime()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationObserver.stop()
        agentRuntimeTask?.cancel()
        agentRuntimeTask = nil
        bridgeController.stop()
        mediaRuntime.stop()
        shellController.applicationWillTerminate(notification)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shellController.applicationShouldTerminateAfterLastWindowClosed(sender)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        shellController.applicationSupportsSecureRestorableState(app)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return updaterController.canCheckForUpdates
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc private func exportSupportBundle(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await telemetry.exportJSON()
                try saveSupportBundle(data)
            } catch {
                presentSupportBundleError()
            }
        }
    }

    private func startAgentRuntime() {
        guard agentRuntimeTask == nil else { return }
        let runtime = agentRuntime
        agentRuntimeTask = Task { @MainActor [weak self] in
            let cachedState = await runtime.loadCachedState()
            self?.apply(cachedState)
            _ = await runtime.discoverProviders()
            while !Task.isCancelled {
                let liveState = await runtime.refreshAll()
                guard !Task.isCancelled else { return }
                self?.apply(liveState)
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
            }
        }
    }

    private func apply(_ runtimeSnapshot: DirectAgentRuntimeSnapshot) {
        for state in runtimeSnapshot.providers {
            shellController.model.apply(
                provider: state.provider,
                snapshot: state.usageSnapshot,
                connection: state.connectionState
            )
        }
    }

    private func migrateLegacyPreferencesForOfficialBuild() {
        guard Bundle.main.bundleIdentifier == "com.notchhub.app",
              let legacyDefaults = UserDefaults(suiteName: "com.notchhub.app")
        else { return }
        _ = LegacyPreferencesMigrator.migrate(from: legacyDefaults, to: .standard)
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu(title: "NotchHub V1")
        let appItem = NSMenuItem(title: "NotchHub V1", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "NotchHub V1")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.toolTip = updaterController.isConfigured ? nil : "This build has no signed HTTPS update feed."
        appMenu.addItem(updateItem)
        let exportItem = NSMenuItem(
            title: "Export Redacted Support Bundle…",
            action: #selector(exportSupportBundle(_:)),
            keyEquivalent: ""
        )
        exportItem.target = self
        appMenu.addItem(exportItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit NotchHub V1",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        NSApp.mainMenu = mainMenu
    }

    private func saveSupportBundle(_ data: Data) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NotchHub-Support.json"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try SecureFileIO.writeAtomically(data, to: destination)
    }

    private func presentSupportBundleError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Support bundle could not be exported"
        alert.informativeText = "No diagnostics were written. Choose another writable location and try again."
        alert.runModal()
    }
}

@MainActor
private final class PresentationNotificationObserver {
    private let model: AppPresentationModel
    private let controller: SmartQuietNotificationController
    private var deliveryTask: Task<Void, Never>?
    private var isRunning = false

    init(
        model: AppPresentationModel,
        controller: SmartQuietNotificationController = .init()
    ) {
        self.model = model
        self.controller = controller
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        captureObservation()
    }

    func stop() {
        isRunning = false
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func captureObservation() {
        guard isRunning else { return }
        let observation = withObservationTracking {
            SmartQuietObservation(presentationModel: model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.captureObservation()
            }
        }
        enqueue(observation)
    }

    private func enqueue(_ observation: SmartQuietObservation) {
        let precedingTask = deliveryTask
        let controller = controller
        deliveryTask = Task {
            if let precedingTask {
                await precedingTask.value
            }
            _ = await controller.observe(observation)
        }
    }
}
