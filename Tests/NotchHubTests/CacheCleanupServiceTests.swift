import Foundation
import Testing
@testable import NotchHub

/// The scan and clean as the panel sees them.
///
/// Nothing here touches a real folder: every disk operation is a closure on
/// `CleanupStage`. That is deliberate — a bug in this suite must not be able
/// to move anything on the machine running it.
@Suite("Cache cleanup")
@MainActor
struct CacheCleanupServiceTests {

    // MARK: - Scanning

    @Test
    func aScanCountsSafeAndCheckFirstSeparately() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 300)
        stage.cache("com.apple.Spotlight", megabytes: 50)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        guard let found = rig.summary() else {
            Issue.record("Expected a finished scan, got \(rig.service.state)")
            return
        }
        #expect(found.safeBytes == 300 * 1024 * 1024)
        #expect(found.safeCount == 1)
        #expect(found.checkFirstCount == 1)
        #expect(rig.service.state == .ready(found))
    }

    /// The one that matters most: a folder nobody recognises is not listed, and
    /// an account daemon's cache is not even measured.
    @Test
    func unknownAndProtectedFoldersAreNeverEvenSized() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 100)
        stage.cache("com.example.notchhubtest", megabytes: 900)
        stage.cache("com.apple.accountsd", megabytes: 900)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        let paths = rig.service.candidates.map(\.url.lastPathComponent)
        #expect(paths == ["com.google.Chrome"])
        #expect(!stage.sizedPaths.contains { $0.contains("notchhubtest") })
        #expect(!stage.sizedPaths.contains { $0.contains("accountsd") })
    }

    /// Under the 64 MB floor there is nothing worth offering, and the panel
    /// says so in its own words rather than showing a number.
    @Test
    func aSmallResultIsReportedAsTidyRatherThanReady() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 5)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        guard case .tidy = rig.service.state else {
            Issue.record("Expected tidy, got \(rig.service.state)")
            return
        }
    }

    @Test
    func developerCachesArriveOnlyWithTheSwitch() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 100)
        stage.developerCache("Library/Developer/Xcode/DerivedData", megabytes: 4_000)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        #expect(rig.service.candidates.count == 1)

        rig.preferences.includeDeveloperCaches = true
        rig.service.scan()
        await rig.settle()
        #expect(rig.service.candidates.contains { $0.kind == .developerTool && $0.title == "Xcode Build Files" })
        #expect(rig.summary()?.includedDeveloperCaches == true)
    }

    /// Containers are TCC-guarded; entering one without the grant is what
    /// raises a folder prompt, so the scan does not look until it is granted.
    @Test
    func containersAreEnteredOnlyWithFullDiskAccess() async {
        let denied = CleanupStage(fullDiskAccess: false)
        denied.cache("com.google.Chrome", megabytes: 100)
        denied.container("com.spotify.client", megabytes: 200)
        guard let rig = CleanupRig(stage: denied) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        #expect(!rig.service.candidates.contains { $0.kind == .container })

        let granted = CleanupStage(fullDiskAccess: true)
        granted.cache("com.google.Chrome", megabytes: 100)
        granted.container("com.spotify.client", megabytes: 200)
        granted.container("com.apple.Safari", megabytes: 900)
        guard let secondRig = CleanupRig(stage: granted) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { secondRig.tearDown() }

        secondRig.service.scan()
        await secondRig.settle()
        let containers = secondRig.service.candidates.filter { $0.kind == .container }
        #expect(containers.count == 1)
        #expect(containers.first?.deleteContentsOnly == true)
        #expect(!containers.contains { $0.url.path.contains("com.apple.Safari") })
    }

    /// A missing `~/Library/Logs` is not a failure — there is simply nothing
    /// there to clean.
    @Test
    func aMissingSecondaryFolderIsNotAFailure() async {
        let stage = CleanupStage()
        stage.cache("com.google.Chrome", megabytes: 100)
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()
        #expect(rig.summary() != nil)
    }

    @Test
    func anUnreadableCachesFolderIsReportedWithItsReason() async {
        let stage = CleanupStage()
        stage.failListing("Library/Caches", with: NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "the disk is unreadable"]
        ))
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        guard case let .failed(error) = rig.service.state else {
            Issue.record("Expected a failure, got \(rig.service.state)")
            return
        }
        #expect(error == .folderUnreadable(folder: "~/Library/Caches", reason: "the disk is unreadable"))
        #expect(error.settingsPane == nil)
        #expect(error.message.contains("~/Library/Caches"))
    }

    /// A refusal from macOS is a different problem with a different fix, and
    /// the panel has to point at the pane that fixes it.
    @Test
    func aRefusedFolderPointsAtFullDiskAccess() async {
        let stage = CleanupStage()
        stage.failListing("Library/Caches", with: NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError
        ))
        guard let rig = CleanupRig(stage: stage) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { rig.tearDown() }

        rig.service.scan()
        await rig.settle()

        guard case let .failed(error) = rig.service.state else {
            Issue.record("Expected a failure, got \(rig.service.state)")
            return
        }
        #expect(error == .permissionRefused(folder: "~/Library/Caches"))
        #expect(error.settingsPane == .fullDiskAccess)
    }
}
