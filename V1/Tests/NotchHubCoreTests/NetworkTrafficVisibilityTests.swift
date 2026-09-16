import Foundation
import NotchHubNetwork
import Testing
@testable import NotchHubCore

@MainActor
@Suite("Network traffic display lifecycle")
struct NetworkTrafficVisibilityTests {
    private let contentID = UUID()

    @Test("Traffic reads require both selection and visible detail content")
    func selectionRequiresVisibleContent() {
        let recorder = NetworkLifecycleRecorder()
        let lifecycle = recorder.lifecycle()
        lifecycle.setSelected(true)
        #expect(recorder.starts == 0)
        lifecycle.setContentVisible(true, id: contentID)
        lifecycle.setContentVisible(true, id: contentID)
        lifecycle.setSelected(true)
        #expect(recorder.starts == 1)
        lifecycle.setContentVisible(false, id: contentID)
        #expect(recorder.stops == 1)
        lifecycle.setContentVisible(true, id: contentID)
        #expect(recorder.starts == 2)
        lifecycle.setSelected(false)
        lifecycle.setContentVisible(false, id: contentID)
        #expect(recorder.stops == 2)
        #expect(!lifecycle.isRunning)
    }

    @Test("Shutdown prevents delayed appearance from restarting monitoring")
    func shutdownIsTerminal() {
        let recorder = NetworkLifecycleRecorder()
        let lifecycle = recorder.lifecycle()
        lifecycle.setContentVisible(true, id: contentID)
        lifecycle.setSelected(true)
        lifecycle.shutdown()
        lifecycle.shutdown()
        lifecycle.setContentVisible(true, id: contentID)
        #expect(recorder.starts == 1)
        #expect(recorder.stops == 1)
    }

    @Test("A disappearing old transition cannot stop newly visible Network content")
    func staleTransitionDoesNotStopReplacement() {
        let recorder = NetworkLifecycleRecorder()
        let lifecycle = recorder.lifecycle()
        let replacementID = UUID()
        lifecycle.setSelected(true)
        lifecycle.setContentVisible(true, id: contentID)
        lifecycle.setSelected(false)
        lifecycle.setSelected(true)
        #expect(lifecycle.isRunning)
        lifecycle.setContentVisible(true, id: replacementID)
        lifecycle.setContentVisible(false, id: contentID)
        #expect(lifecycle.isRunning)
        #expect(recorder.starts == 2)
        #expect(recorder.stops == 1)
        lifecycle.setContentVisible(false, id: replacementID)
        #expect(!lifecycle.isRunning)
    }

    @Test("Compact presentation and switching capabilities remove traffic demand")
    func presentationSelectionLifecycle() {
        let network = NetworkTrafficModel(monitor: PresentationTrafficMonitor())
        let model = AppPresentationModel(edition: .direct, network: network)
        #expect(model.network === network)
        model.select(.network)
        #expect(!model.networkVisibility.isRunning)
        model.setNetworkContentVisible(true, id: contentID)
        #expect(model.networkVisibility.isRunning)
        model.showCompact()
        #expect(!model.networkVisibility.isRunning)
        model.showDetail()
        #expect(model.networkVisibility.isRunning)
        model.setNetworkContentVisible(false, id: contentID)
        #expect(!model.networkVisibility.isRunning)
        model.setNetworkContentVisible(true, id: contentID)
        #expect(model.networkVisibility.isRunning)
        model.select(.dashboard)
        #expect(!model.networkVisibility.isRunning)
        model.stopNetworkMonitoring()
    }

    @Test("Lite never asks the network model to run")
    func liteRemainsIsolated() {
        let network = NetworkTrafficModel(monitor: PresentationTrafficMonitor())
        let model = AppPresentationModel(edition: .lite, network: network)
        model.setNetworkContentVisible(true, id: contentID)
        model.select(.network)
        model.showDetail()
        #expect(model.network == nil)
        #expect(!model.networkVisibility.isRunning)
    }

    @Test("An approval taking over the ribbon stops passive traffic sampling")
    func approvalTakesOverNetworkDetail() {
        let network = NetworkTrafficModel(monitor: PresentationTrafficMonitor())
        let model = AppPresentationModel(edition: .direct, network: network)
        model.select(.network)
        model.setNetworkContentVisible(true, id: contentID)
        model.presentApproval(.init(
            id: "approval", providerName: "Codex", projectName: "Project",
            actionCategory: "Command", preview: nil, risk: .elevated, expiresAt: .distantFuture
        ))
        #expect(model.selectedCapability == .agents)
        #expect(!model.networkVisibility.isRunning)
        #expect(!network.isRunning)
        model.stopNetworkMonitoring()
    }
}

private actor PresentationTrafficMonitor: NetworkTrafficMonitoring {
    func updates() -> AsyncStream<NetworkTrafficSnapshot> {
        AsyncStream { _ in }
    }

    func start() {}
    func stop() {}
}

@MainActor
private final class NetworkLifecycleRecorder {
    var starts = 0
    var stops = 0

    func lifecycle() -> NetworkTrafficVisibility {
        NetworkTrafficVisibility(start: { self.starts += 1 }, stop: { self.stops += 1 })
    }
}
