import Foundation
import Testing
@testable import NotchHub

/// The switches and the remembered numbers. A defaults domain is a file
/// anything running as the user can write, so what comes back out of it is
/// checked before the panel is allowed to show it.
@Suite("Cleanup preferences")
@MainActor
struct CleanupPreferencesTests {

    private func isolatedDefaults(_ label: String) -> (UserDefaults, String)? {
        let suite = "CleanupPreferencesTests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        return (defaults, suite)
    }

    private func summary(
        safeBytes: Int64 = 100,
        date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> CacheScanSummary {
        CacheScanSummary(
            safeBytes: safeBytes, safeCount: 2, checkFirstBytes: 10, checkFirstCount: 1,
            date: date, includedDeveloperCaches: false, includedContainers: false
        )
    }

    @Test
    func aFreshInstallShowsCleanupAndHidesDeveloperCaches() {
        guard let (defaults, suite) = isolatedDefaults("fresh") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = CleanupPreferences(defaults: defaults)
        #expect(preferences.showInFocus)
        #expect(preferences.includeDeveloperCaches == false)
        #expect(preferences.lastScan == nil)
        #expect(preferences.lastClean == nil)
    }

    @Test
    func switchesAndSummariesSurviveARelaunch() {
        guard let (defaults, suite) = isolatedDefaults("relaunch") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = CleanupPreferences(defaults: defaults)
        first.showInFocus = false
        first.includeDeveloperCaches = true
        first.recordScan(summary())
        first.recordClean(CleanSummary(
            movedBytes: 2048, movedCount: 3, failedCount: 0, skippedCount: 1,
            firstFailure: nil, date: Date(timeIntervalSince1970: 1_000_500)
        ))

        let second = CleanupPreferences(defaults: defaults)
        #expect(second.showInFocus == false)
        #expect(second.includeDeveloperCaches)
        #expect(second.lastScan == summary())
        #expect(second.lastClean?.movedCount == 3)
        #expect(second.lastClean?.skippedCount == 1)
    }

    @Test
    func aChangedSwitchTellsTheHub() {
        guard let (defaults, suite) = isolatedDefaults("onChange") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = CleanupPreferences(defaults: defaults)
        var changes = 0
        preferences.onChange = { changes += 1 }
        preferences.showInFocus = false
        preferences.includeDeveloperCaches = true
        #expect(changes == 2)
    }

    /// Corrupt stored data is dropped rather than shown. The panel then says
    /// "not scanned yet", which is true, instead of a number from nowhere.
    @Test
    func unusableStoredDataIsDiscarded() {
        guard let (defaults, suite) = isolatedDefaults("corrupt") else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not json".utf8), forKey: "cleanup.lastScan")
        #expect(CleanupPreferences(defaults: defaults).lastScan == nil)
    }

    @Test
    func negativeOrFutureSummariesAreRejected() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(CleanupPreferences.validated(summary(safeBytes: -1), now: now) == nil)
        #expect(CleanupPreferences.validated(summary(date: now.addingTimeInterval(60)), now: now) == nil)
        #expect(CleanupPreferences.validated(summary(), now: now) != nil)
        let clean = CleanSummary(
            movedBytes: -5, movedCount: 1, failedCount: 0, skippedCount: 0, firstFailure: nil, date: now
        )
        #expect(CleanupPreferences.validated(clean, now: now) == nil)
    }

    /// After a clean the stored number is corrected immediately, so quitting
    /// during the six-second hold does not bring the pre-clean figure back.
    @Test
    func aCleanIsSubtractedFromTheStoredScan() {
        let scan = summary(safeBytes: 10_000)
        let clean = CleanSummary(
            movedBytes: 4_000, movedCount: 1, failedCount: 0, skippedCount: 0,
            firstFailure: nil, date: Date(timeIntervalSince1970: 1_000_100)
        )
        let after = scan.subtracting(clean)
        #expect(after.safeBytes == 6_000)
        #expect(after.safeCount == 1)
        #expect(after.checkFirstCount == scan.checkFirstCount)
    }

    /// Cleaning more than the last scan counted (it can happen — the scan is a
    /// moment old) must not produce a negative number on the panel.
    @Test
    func subtractingMoreThanWasFoundStopsAtZero() {
        let scan = summary(safeBytes: 100)
        let clean = CleanSummary(
            movedBytes: 500, movedCount: 9, failedCount: 0, skippedCount: 0,
            firstFailure: nil, date: Date(timeIntervalSince1970: 1_000_100)
        )
        let after = scan.subtracting(clean)
        #expect(after.safeBytes == 0)
        #expect(after.safeCount == 0)
    }
}
