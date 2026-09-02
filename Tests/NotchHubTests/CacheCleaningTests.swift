import Foundation
import Testing
@testable import NotchHub

/// Moving folders to the Trash, and the lifecycle around it.
///
/// Split from `CacheCleanupServiceTests` so each suite stays inside the
/// 300-line type-body cap; the rig they share lives in `CacheCleanupFakes`.
@Suite("Cache cleaning")
@MainActor
struct CacheCleaningTests {

    // MARK: - Cleaning

    @Test
    func cleaningMovesEverySafeFolderAndNoCheckFirstOne() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        stage.cache("com.apple.Spotlight", megabytes: 500)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        rig.service.cleanSafe()
        await rig.settle()

        #expect(stage.trashed.map(\.lastPathComponent) == ["com.google.Chrome"])
        guard case let .cleaned(result) = rig.service.state else {
            Issue.record("Expected a finished clean, got \(rig.service.state)")
            return
        }
        #expect(result.movedCount == 1)
        #expect(result.movedBytes == 300 * 1024 * 1024)
        #expect(result.failedCount == 0)
    }

    /// A container's cache folder has to survive; only what is inside it goes.
    @Test
    func aContainerKeepsItsCacheFolderAndLosesItsContents() async {
        let stage = CleanupStage(fullDiskAccess: true)
        stage.cache("com.google.Chrome", megabytes: 100)
        stage.container("com.spotify.client", megabytes: 200, children: ["Images", "Audio"])
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        rig.service.cleanSafe()
        await rig.settle()

        let trashed = stage.trashed.map(\.lastPathComponent)
        #expect(trashed.contains("Images"))
        #expect(trashed.contains("Audio"))
        #expect(!trashed.contains("Caches"))
    }

    /// A folder that refuses to move is reported, not swallowed.
    @Test
    func aFailedMoveIsCountedAndNamed() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        stage.cache("com.spotify.client", megabytes: 200)
        stage.failTrash(of: stage.url("Library/Caches/com.spotify.client"))
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        rig.service.cleanSafe()
        await rig.settle()

        guard case let .cleaned(result) = rig.service.state else {
            Issue.record("Expected a finished clean, got \(rig.service.state)")
            return
        }
        #expect(result.movedCount == 1)
        #expect(result.failedCount == 1)
        #expect(result.firstFailure?.contains("in use") == true)
    }

    /// If nothing at all moved, saying "moved 0 bytes" would be a lie of tone;
    /// it is a failure, with the reason attached.
    @Test
    func aCleanThatMovesNothingIsAFailure() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        stage.failTrash(of: stage.url("Library/Caches/com.google.Chrome"))
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        rig.service.cleanSafe()
        await rig.settle()

        guard case let .failed(error) = rig.service.state else {
            Issue.record("Expected a failure, got \(rig.service.state)")
            return
        }
        #expect(error == .nothingMoved(attempted: 1, reason: "Google Chrome: the folder is in use"))
    }

    /// The result stands for a moment, then a rescan replaces it — which is
    /// how the panel gets back to a number without the user asking.
    @Test
    func theResultIsHeldBrieflyThenRescanned() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        let recorder = ScheduleRecorder()
        guard let rig = CleanupRig(stage: stage, recorder: recorder) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        rig.service.cleanSafe()
        await rig.settle()

        #expect(recorder.delays == [CacheCleanupService.resultHold])
        recorder.fire()
        await rig.settle()
        // The rescan sees a Mac with the cache gone, so the panel settles on
        // "tidy" rather than the number it was showing a moment ago.
        guard case .tidy = rig.service.state else {
            Issue.record("Expected a rescan to follow the hold, got \(rig.service.state)")
            return
        }
        #expect(rig.summary()?.safeBytes == 0)
    }

    // MARK: - Lifecycle

    /// A stopped scan's answer must never arrive late and overwrite what the
    /// panel is showing now.
    @Test
    func aStoppedScanDiscardsItsAnswer() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        rig.service.stop()
        await rig.settle()

        #expect(rig.service.state == .unscanned)
        #expect(rig.service.candidates.isEmpty)
    }

    @Test
    func hidingTheSegmentStopsItScanning() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        guard let rig = CleanupRig(stage: stage, showInFocus: false) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.refreshIfStale()
        rig.service.scan()
        await rig.settle()

        #expect(rig.service.state == .unscanned)
        #expect(stage.sizedPaths.isEmpty)
    }

    /// Opening the panel with a number a few minutes old shows it straight
    /// away; an hour later it is worth counting again.
    @Test
    func aRecentResultIsKeptAndAnOldOneIsRefreshed() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        let clock = CleanupClock()
        guard let rig = CleanupRig(stage: stage, clock: clock) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        clock.advance(600)
        #expect(rig.service.isStale(at: clock.date) == false)

        clock.advance(3_600)
        #expect(rig.service.isStale(at: clock.date))
    }

    /// Turning on developer caches makes the stored number wrong, whatever its
    /// age — so the next open counts again.
    @Test
    func aChangedSwitchMakesTheStoredNumberStale() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        let clock = CleanupClock()
        guard let rig = CleanupRig(stage: stage, clock: clock) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        #expect(rig.service.isStale(at: clock.date) == false)

        rig.preferences.includeDeveloperCaches = true
        #expect(rig.service.isStale(at: clock.date))
    }

    /// The panel has a number the moment the app starts, without reading a
    /// single folder.
    @Test
    func aStoredResultIsShownBeforeAnythingIsRead() {
        let suite = "CacheCleanupServiceTests.restore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = CleanupPreferences(defaults: defaults)
        let stored = CacheScanSummary(
            safeBytes: 900 * 1024 * 1024, safeCount: 4, checkFirstBytes: 0, checkFirstCount: 0,
            date: Date(timeIntervalSince1970: 1_700_000_000), includedDeveloperCaches: false, includedContainers: false
        )
        preferences.recordScan(stored)

        let stage = CleanupStage()
        let service = CacheCleanupService(
            preferences: CleanupPreferences(defaults: defaults),
            io: stage.io(),
            home: CleanupStage.home,
            now: { Date(timeIntervalSince1970: 1_700_000_060) },
            schedule: { _, _ in }
        )
        #expect(service.state == .ready(stored))
        #expect(stage.sizedPaths.isEmpty)
    }
}
