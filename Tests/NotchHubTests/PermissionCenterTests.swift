import EventKit
import Foundation
import Testing
@testable import NotchHub

/// NotchHub cannot grant itself anything, so the value here is in being honest
/// about what is missing and pointing at the one place that fixes it.
@Suite("Permissions")
@MainActor
struct PermissionCenterTests {

    /// Statuses come straight from the probes, with no permission left unread.
    @Test
    func everyPermissionGetsAStatus() async {
        let center = PermissionCenter(probes: probes(all: .denied), defaults: freshDefaults())

        await center.refreshAll()

        for permission in PermissionCenter.Permission.allCases {
            #expect(center.status(of: permission) == .denied)
        }
        #expect(center.outstanding.count == PermissionCenter.Permission.allCases.count)
    }

    /// Granted permissions drop off the list of things still to do.
    @Test
    func grantedPermissionsAreNotOutstanding() async {
        var probes = probes(all: .granted)
        probes.accessibility = { .denied }
        let center = PermissionCenter(probes: probes, defaults: freshDefaults())

        await center.refreshAll()

        #expect(center.outstanding == [.accessibility])
    }

    /// Full Disk Access has no prompt — asking must open the pane rather than
    /// silently doing nothing.
    @Test
    func fullDiskAccessIsNotPromptable() {
        #expect(PermissionCenter.Permission.fullDiskAccess.isPromptable == false)
        #expect(PermissionCenter.Permission.fullDiskAccess.settingsPane == .fullDiskAccess)
        for promptable in PermissionCenter.Permission.allCases where promptable != .fullDiskAccess {
            #expect(promptable.isPromptable)
        }
    }

    /// A prompt that has already been answered never appears again, so a denied
    /// permission has to fall through to the pane or the button does nothing —
    /// which is exactly what made these look ungrantable.
    @Test
    func requestingADeniedPromptableAlsoRoutesToSettings() async {
        var opened: [SystemSettingsPane] = []
        var requests = PermissionCenter.Requests()
        requests.openPane = { opened.append($0) }
        let center = PermissionCenter(
            probes: probes(all: .denied),
            requests: requests,
            defaults: freshDefaults()
        )
        await center.refreshAll()

        center.request(.accessibility)

        #expect(opened == [.accessibility])
    }

    /// An unanswered prompt is worth raising on its own — no pane needed yet.
    @Test
    func requestingAnUnaskedPromptableDoesNotOpenSettings() async {
        var opened: [SystemSettingsPane] = []
        var requests = PermissionCenter.Requests()
        requests.openPane = { opened.append($0) }
        let center = PermissionCenter(
            probes: probes(all: .notDetermined),
            requests: requests,
            defaults: freshDefaults()
        )
        await center.refreshAll()

        center.request(.accessibility)

        #expect(opened.isEmpty)
    }

    /// Full Disk Access has no prompt at all, so asking can only mean "take me
    /// to the switch".
    @Test
    func requestingFullDiskAccessOnlyOpensThePane() async {
        var opened: [SystemSettingsPane] = []
        var requests = PermissionCenter.Requests()
        requests.openPane = { opened.append($0) }
        let center = PermissionCenter(
            probes: probes(all: .unknown),
            requests: requests,
            defaults: freshDefaults()
        )
        await center.refreshAll()

        center.request(.fullDiskAccess)

        #expect(opened == [.fullDiskAccess])
    }

    /// Each promptable permission routes to its own request, not a shared one.
    @Test
    func eachPermissionFiresItsOwnPrompt() async {
        var fired: [String] = []
        var requests = PermissionCenter.Requests()
        requests.accessibility = { fired.append("accessibility") }
        requests.automation = { fired.append("automation") }
        requests.calendar = { fired.append("calendar") }
        requests.reminders = { fired.append("reminders") }
        requests.notifications = { fired.append("notifications") }
        requests.openPane = { _ in }
        let center = PermissionCenter(
            probes: probes(all: .notDetermined),
            requests: requests,
            defaults: freshDefaults()
        )
        await center.refreshAll()

        center.request(.accessibility)
        center.request(.automation)
        center.request(.calendar)
        center.request(.reminders)
        center.request(.notifications)
        center.request(.fullDiskAccess) // no prompt exists; must not crash

        #expect(fired == ["accessibility", "automation", "calendar", "reminders", "notifications"])
    }

    /// Onboarding is a first-run thing, and finishing it is remembered.
    @Test
    func onboardingShowsOnceThenNeverAgain() {
        let defaults = freshDefaults()
        let center = PermissionCenter(probes: probes(all: .denied), defaults: defaults)

        #expect(center.shouldShowOnboarding)
        center.markOnboardingComplete()
        #expect(center.shouldShowOnboarding == false)

        // A fresh instance reads the same persisted answer.
        let relaunched = PermissionCenter(probes: probes(all: .denied), defaults: defaults)
        #expect(relaunched.shouldShowOnboarding == false)
    }

    /// EventKit's several "no" states collapse to the two answers the UI can
    /// act on, and only a real grant reads as granted.
    @Test
    func eventKitStatusesMapToSomethingActionable() {
        #expect(PermissionCenter.eventKitStatus(.fullAccess) == .granted)
        #expect(PermissionCenter.eventKitStatus(.notDetermined) == .notDetermined)
        #expect(PermissionCenter.eventKitStatus(.denied) == .denied)
        #expect(PermissionCenter.eventKitStatus(.restricted) == .denied)
        // Write-only can add events but cannot read them, so every NotchHub
        // feature that lists them is still unavailable.
        #expect(PermissionCenter.eventKitStatus(.writeOnly) == .denied)
    }

    // MARK: - Helpers

    private func probes(all status: PermissionStatus) -> PermissionCenter.Probes {
        PermissionCenter.Probes(
            accessibility: { status },
            automation: { status },
            calendar: { status },
            reminders: { status },
            notifications: { status },
            fullDiskAccess: { status }
        )
    }

    private func freshDefaults() -> UserDefaults {
        // A per-test suite so one test's "onboarding done" never leaks into
        // another, and nothing touches the real app domain.
        UserDefaults(suiteName: "notchhub.tests.\(UUID().uuidString)") ?? .standard
    }
}
