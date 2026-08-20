import Foundation
import Testing
@testable import NotchHub

@Suite("Single NotchHub Instance")
struct AppInstanceCoordinatorTests {
    private let oldDate = Date(timeIntervalSince1970: 100)
    private let newDate = Date(timeIntervalSince1970: 200)

    @Test
    func canonicalBundleWinsOverNewerNumberedCopy() {
        let canonical = candidate(pid: 20, name: "NotchHub.app", date: oldDate)
        let numbered = candidate(pid: 10, name: "NotchHub 8.app", date: newDate)

        #expect(AppInstanceSelector.primary(in: [numbered, canonical]) == canonical)
    }

    @Test
    func newestVersionWinsWhenOnlyLegacyCopiesAreRunning() {
        let older = candidate(pid: 10, name: "NotchHub 7.app", version: "0.9.9", date: newDate)
        let latest = candidate(pid: 20, name: "NotchHub 8.app", version: "0.10.0", date: oldDate)

        #expect(AppInstanceSelector.primary(in: [older, latest]) == latest)
    }

    @Test
    func newestBundleWinsWhenVersionsMatch() {
        let older = candidate(pid: 10, name: "NotchHub 7.app", date: oldDate)
        let latest = candidate(pid: 20, name: "NotchHub 8.app", date: newDate)

        #expect(AppInstanceSelector.primary(in: [latest, older]) == latest)
    }

    @Test
    func missingRunningApplicationsIsHandledWithoutCrashing() {
        #expect(AppInstanceSelector.primary(in: []) == nil)
    }

    private func candidate(
        pid: pid_t,
        name: String,
        version: String = "0.1.0",
        date: Date
    ) -> AppInstanceCandidate {
        AppInstanceCandidate(
            processIdentifier: pid,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name)"),
            bundleVersion: version,
            modificationDate: date
        )
    }
}
