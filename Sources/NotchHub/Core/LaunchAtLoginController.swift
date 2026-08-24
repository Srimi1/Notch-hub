import Foundation
import Observation
import ServiceManagement

/// The three `SMAppService` operations the toggle needs, injectable so the
/// binding can be tested without registering a real login item.
struct LaunchAtLoginService {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void

    static let mainApp = LaunchAtLoginService(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() }
    )
}

/// Bridges `SMAppService` into a SwiftUI binding.
///
/// The status is a polled property with no publisher, and macOS posts nothing
/// when the user flips the switch in System Settings ▸ General ▸ Login Items —
/// so the settings window re-reads it on appear rather than trusting a cached
/// value.
@MainActor
@Observable
final class LaunchAtLoginController {

    private(set) var status: SMAppService.Status
    /// Surfaced in the settings window. The old menu item only logged failures,
    /// so a rejected toggle looked like a checkbox that refused to move.
    private(set) var lastError: String?

    @ObservationIgnored private let service: LaunchAtLoginService

    var isEnabled: Bool {
        get { status == .enabled }
        set { apply(enable: newValue) }
    }

    /// States the checkbox alone cannot explain. Treating these as a plain "off"
    /// is what made the toggle look broken: the user checks the box, macOS holds
    /// the registration for approval, and the box silently unchecks itself.
    var statusMessage: String? {
        switch status {
        case .requiresApproval:
            "Approve NotchHub in System Settings ▸ General ▸ Login Items."
        case .notFound:
            "Launch at login needs the built NotchHub.app — it is unavailable when "
                + "running straight from a debug build."
        default:
            nil
        }
    }

    init(service: LaunchAtLoginService = .mainApp) {
        self.service = service
        status = service.status()
    }

    /// Re-read the system's view of the login item.
    func refresh() {
        status = service.status()
    }

    private func apply(enable: Bool) {
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Couldn't change launch at login: \(error.localizedDescription)"
            NSLog("NotchHub: launch-at-login toggle failed: %@", error.localizedDescription)
        }
        refresh()
    }
}
