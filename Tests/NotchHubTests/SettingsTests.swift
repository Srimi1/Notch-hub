import Foundation
import ServiceManagement
import Testing
@testable import NotchHub

/// Launch at login moved out of the menu bar into the settings window, which
/// means it now has to report what the system actually did — the menu item only
/// logged failures, so a rejected toggle looked like a checkbox that wouldn't
/// move.
@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {

    /// Stands in for `SMAppService` so no test registers a real login item.
    private final class FakeService {
        var status: SMAppService.Status
        var registerCount = 0
        var unregisterCount = 0
        var throwsOnChange: Error?

        init(status: SMAppService.Status) { self.status = status }

        func make() -> LaunchAtLoginService {
            LaunchAtLoginService(
                status: { self.status },
                register: {
                    self.registerCount += 1
                    if let error = self.throwsOnChange { throw error }
                    self.status = .enabled
                },
                unregister: {
                    self.unregisterCount += 1
                    if let error = self.throwsOnChange { throw error }
                    self.status = .notRegistered
                }
            )
        }
    }

    private struct RegistrationRefused: Error, LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    @Test
    func enablingRegistersAndReadsTheNewStatusBack() {
        let fake = FakeService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: fake.make())
        #expect(!controller.isEnabled)

        controller.isEnabled = true

        #expect(fake.registerCount == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.lastError == nil)
    }

    @Test
    func disablingUnregisters() {
        let fake = FakeService(status: .enabled)
        let controller = LaunchAtLoginController(service: fake.make())

        controller.isEnabled = false

        #expect(fake.unregisterCount == 1)
        #expect(!controller.isEnabled)
    }

    @Test
    func aFailedToggleSurfacesTheErrorInsteadOfSwallowingIt() {
        let fake = FakeService(status: .notRegistered)
        fake.throwsOnChange = RegistrationRefused()
        let controller = LaunchAtLoginController(service: fake.make())

        controller.isEnabled = true

        #expect(controller.lastError != nil)
        #expect(controller.lastError?.contains("Operation not permitted") == true)
        #expect(!controller.isEnabled)
    }

    /// `.requiresApproval` is not "off" — macOS is holding the registration for
    /// the user to approve. Reporting it as a bare unchecked box is why the old
    /// toggle looked like it silently refused.
    @Test
    func approvalRequiredIsExplainedRatherThanReportedAsOff() {
        let fake = FakeService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: fake.make())

        #expect(!controller.isEnabled)
        #expect(controller.statusMessage != nil)
    }

    @Test
    func anEnabledItemNeedsNoExplanation() {
        let fake = FakeService(status: .enabled)
        let controller = LaunchAtLoginController(service: fake.make())

        #expect(controller.isEnabled)
        #expect(controller.statusMessage == nil)
    }

    // MARK: - First-run default

    private func isolatedDefaults() -> (UserDefaults, String)? {
        let suite = "LaunchAtLoginTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        return (defaults, suite)
    }

    /// A menu-bar utility is expected to come back after a restart, so the first
    /// run opts in without asking.
    @Test
    func firstRunEnablesLaunchAtLogin() {
        guard let (defaults, suite) = isolatedDefaults() else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fake = FakeService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: fake.make(), defaults: defaults)

        controller.enableByDefaultOnFirstRun()

        #expect(fake.registerCount == 1)
        #expect(controller.isEnabled)
    }

    /// The whole point of the flag: someone who turns it off stays off.
    @Test
    func aUserWhoTurnsItOffIsNotReEnrolledOnTheNextLaunch() {
        guard let (defaults, suite) = isolatedDefaults() else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fake = FakeService(status: .notRegistered)
        LaunchAtLoginController(service: fake.make(), defaults: defaults)
            .enableByDefaultOnFirstRun()
        #expect(fake.registerCount == 1)

        // User switches it off, then relaunches the app.
        fake.status = .notRegistered
        LaunchAtLoginController(service: fake.make(), defaults: defaults)
            .enableByDefaultOnFirstRun()

        #expect(fake.registerCount == 1)
    }

    /// A failed registration still burns the flag — otherwise a Mac that refuses
    /// the login item would be re-asked on every single launch.
    @Test
    func aFailedFirstRunAttemptIsNotRetriedForever() {
        guard let (defaults, suite) = isolatedDefaults() else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fake = FakeService(status: .notRegistered)
        fake.throwsOnChange = RegistrationRefused()
        LaunchAtLoginController(service: fake.make(), defaults: defaults)
            .enableByDefaultOnFirstRun()
        LaunchAtLoginController(service: fake.make(), defaults: defaults)
            .enableByDefaultOnFirstRun()

        #expect(fake.registerCount == 1)
    }

    /// Nothing to do when macOS already has the registration.
    @Test
    func anAlreadyEnabledItemIsLeftAlone() {
        guard let (defaults, suite) = isolatedDefaults() else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fake = FakeService(status: .enabled)
        LaunchAtLoginController(service: fake.make(), defaults: defaults)
            .enableByDefaultOnFirstRun()

        #expect(fake.registerCount == 0)
    }

    /// The window re-reads on appear because the switch can also be flipped in
    /// System Settings, which posts no notification.
    @Test
    func refreshPicksUpAnExternalChange() {
        let fake = FakeService(status: .enabled)
        let controller = LaunchAtLoginController(service: fake.make())
        #expect(controller.isEnabled)

        fake.status = .notRegistered
        controller.refresh()

        #expect(!controller.isEnabled)
    }
}
