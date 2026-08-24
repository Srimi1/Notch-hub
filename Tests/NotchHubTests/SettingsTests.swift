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
