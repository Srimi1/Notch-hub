import Foundation
import NotchHubCore
import Sparkle

@MainActor
final class DirectUpdaterController: NSObject {
    private let updaterController: SPUStandardUpdaterController?
    private(set) var hasStarted = false

    var isConfigured: Bool {
        updaterController != nil
    }

    var canCheckForUpdates: Bool {
        hasStarted && updaterController?.updater.canCheckForUpdates == true
    }

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        if UpdateFeedConfiguration(infoDictionary: infoDictionary) != nil {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            self.updaterController = nil
        }
        super.init()
    }

    func startIfConfigured() {
        guard !hasStarted, let updaterController else { return }
        updaterController.startUpdater()
        hasStarted = true
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        updaterController?.checkForUpdates(sender)
    }
}
