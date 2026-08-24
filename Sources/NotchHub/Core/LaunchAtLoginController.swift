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

    /// Set once the app has tried to turn launch-at-login on by itself, so it
    /// never fights a user who deliberately turned it off.
    static let defaultEnableKey = "didAttemptDefaultLaunchAtLogin"

    @ObservationIgnored private let defaults: UserDefaults

    init(service: LaunchAtLoginService = .mainApp, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        status = service.status()
    }

    /// Turn launch-at-login on the first time the app ever runs, because "it
    /// should just always start" is the expectation for a menu-bar utility.
    ///
    /// Runs at most once in the app's lifetime: the flag is written whether or
    /// not registration succeeds, so a user who later switches it off — or whose
    /// Mac refuses the registration — is not re-enrolled on the next launch.
    func enableByDefaultOnFirstRun() {
        guard !defaults.bool(forKey: Self.defaultEnableKey) else { return }
        defaults.set(true, forKey: Self.defaultEnableKey)
        guard status == .notRegistered else { return }
        apply(enable: true)
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
