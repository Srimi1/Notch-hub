import Foundation
import Testing
@testable import NotchHub

/// The words the cache segment shows.
///
/// Worth a suite of its own because the design rules make claims about them:
/// four distinct states must not share a sentence, an error must read as an
/// error, and nothing may say "freed" about files that are still in the Trash.
@Suite("Cleanup copy")
struct CleanupCopyTests {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func summary(
        safeBytes: Int64 = 1_073_741_824,
        checkFirstCount: Int = 0,
        minutesAgo: Double = 5
    ) -> CacheScanSummary {
        CacheScanSummary(
            safeBytes: safeBytes, safeCount: 3, checkFirstBytes: 1024, checkFirstCount: checkFirstCount,
            date: now.addingTimeInterval(-minutesAgo * 60),
            includedDeveloperCaches: false, includedContainers: false
        )
    }

    @Test
    func aNeverScannedMacSaysSoAndOffersToScan() {
        let copy = CleanupCopy.make(state: .unscanned, now: now)
        #expect(copy.title == "Caches")
        #expect(copy.caption == "Not scanned yet")
        #expect(copy.action == .scan)
        #expect(copy.isActionEnabled)
        #expect(copy.isError == false)
    }

    /// "Nothing found yet" and "nothing to find" are different facts, and the
    /// design rules say they must not share a string.
    @Test
    func nothingToCleanReadsDifferentlyFromNotScannedYet() {
        let tidy = CleanupCopy.make(state: .tidy(summary(safeBytes: 1024)), now: now)
        let unscanned = CleanupCopy.make(state: .unscanned, now: now)
        #expect(tidy.title == "Caches are tidy")
        #expect(tidy.caption == "Under 64 MB to clean · 5m ago")
        #expect(tidy.title != unscanned.title)
        #expect(tidy.caption != unscanned.caption)
        #expect(tidy.action == .rescan)
    }

    @Test
    func aReadyScanNamesTheAmountAndWhenItWasCounted() {
        let copy = CleanupCopy.make(state: .ready(summary()), now: now)
        #expect(copy.title == "1.07 GB safe to clean")
        #expect(copy.caption == "Scanned 5m ago")
        #expect(copy.action == .clean)
        #expect(copy.isActionEnabled)
    }

    /// Check-first folders are counted where the user can see them, so the
    /// number on the button and the number on disk do not seem to disagree.
    @Test
    func checkFirstFoldersAreMentionedButNotIncluded() {
        let copy = CleanupCopy.make(state: .ready(summary(checkFirstCount: 3)), now: now)
        #expect(copy.caption == "Scanned 5m ago · 3 to check first")
        let tidy = CleanupCopy.make(state: .tidy(summary(safeBytes: 0, checkFirstCount: 2)), now: now)
        #expect(tidy.caption == "2 to check first · 5m ago")
    }

    @Test
    func aRunningScanShowsWhatItHasCountedSoFar() {
        let starting = CleanupCopy.make(state: .scanning(bytesSoFar: 0), now: now)
        #expect(starting.caption == "Sizing ~/Library/Caches")
        #expect(starting.isActionEnabled == false)

        let counting = CleanupCopy.make(state: .scanning(bytesSoFar: 314_572_800), now: now)
        #expect(counting.title == "Scanning caches…")
        #expect(counting.caption == "314.6 MB found so far")
        #expect(counting.isActionEnabled == false)
    }

    @Test
    func cleaningCountsFoldersAndReadsAsPlainEnglishForOne() {
        #expect(CleanupCopy.make(state: .cleaning(itemCount: 1), now: now).caption
            == "Moving 1 folder to the Trash")
        #expect(CleanupCopy.make(state: .cleaning(itemCount: 4), now: now).caption
            == "Moving 4 folders to the Trash")
    }

    /// The space is not free until the Trash is emptied, and the panel says
    /// exactly that rather than claiming anything was "freed".
    @Test
    func aFinishedCleanPointsAtTheTrashRatherThanClaimingSpace() {
        let result = CleanSummary(
            movedBytes: 314_572_800, movedCount: 2, failedCount: 0, skippedCount: 0, firstFailure: nil, date: now
        )
        let copy = CleanupCopy.make(state: .cleaned(result), now: now)
        #expect(copy.title == "314.6 MB moved to the Trash")
        #expect(copy.caption == "Empty the Trash to free the space")
        #expect(!copy.title.lowercased().contains("freed"))
        #expect(copy.isError == false)
        #expect(copy.isActionEnabled == false)
    }

    @Test
    func foldersThatWouldNotMoveAreReportedOnTheResult() {
        let result = CleanSummary(
            movedBytes: 1024, movedCount: 1, failedCount: 1, skippedCount: 1,
            firstFailure: "Slack: in use", date: now
        )
        let copy = CleanupCopy.make(state: .cleaned(result), now: now)
        #expect(copy.caption == "2 could not be moved")
        #expect(copy.isError)
    }

    /// A scan failure and a clean failure are different problems and say so.
    @Test
    func scanAndCleanFailuresAreToldApart() {
        let scan = CleanupCopy.make(
            state: .failed(.folderUnreadable(folder: "~/Library/Caches", reason: "unreadable")), now: now
        )
        #expect(scan.title == "Could not scan caches")
        #expect(scan.caption.contains("~/Library/Caches"))
        #expect(scan.isError)
        #expect(scan.action == .retry)

        let clean = CleanupCopy.make(
            state: .failed(.nothingMoved(attempted: 3, reason: "every folder was in use")), now: now
        )
        #expect(clean.title == "Could not clean caches")
        #expect(clean.action == .retry)
    }

    /// A permission problem has a pane that fixes it, so the button opens that
    /// pane rather than retrying something that will fail the same way.
    @Test
    func aPermissionFailureOffersThePaneThatFixesIt() {
        let copy = CleanupCopy.make(state: .failed(.permissionRefused(folder: "~/Library/Caches")), now: now)
        #expect(copy.action == .openSettings(.fullDiskAccess))
        #expect(copy.caption.contains(SystemSettingsPane.fullDiskAccess.settingsPath))
    }

    @Test
    func everyStateOffersAnAccessibilityLabel() {
        let states: [CacheCleanupService.State] = [
            .unscanned, .scanning(bytesSoFar: 0), .ready(summary()), .tidy(summary(safeBytes: 0)),
            .cleaning(itemCount: 2),
            .cleaned(CleanSummary(movedBytes: 0, movedCount: 1, failedCount: 0, skippedCount: 0,
                                  firstFailure: nil, date: now)),
            .failed(.permissionRefused(folder: "~/Library/Caches"))
        ]
        for state in states {
            #expect(!CleanupCopy.make(state: state, now: now).accessibilityLabel.isEmpty)
        }
    }
}
