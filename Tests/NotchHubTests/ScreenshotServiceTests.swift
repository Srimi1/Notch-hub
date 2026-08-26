import Foundation
import Testing
@testable import NotchHub

/// Drives the watcher, the folder listing, the classifier and the clock, so the
/// suite never opens a real folder — least of all the Desktop, which would put
/// a permission dialog in front of the test runner.
@Suite("Screenshot auto-copy")
@MainActor
struct ScreenshotServiceTests {

    /// The service plus the pieces a test needs to see inside it.
    private struct Rig {
        var service: ScreenshotService
        var preferences: ScreenshotPreferences
        var watcher: FakeWatcher
        var stage: Stage
        var defaults: UserDefaults
        var suiteName: String
        var captures: () -> [CapturedScreenshot]
    }

    nonisolated static let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeRig(allowingFolder: Bool = true) -> Rig? {
        let suiteName = "ScreenshotServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults")
            return nil
        }
        let preferences = ScreenshotPreferences(defaults: defaults)
        let stage = Stage()
        let watcher = FakeWatcher()
        let box = CaptureBox()

        if allowingFolder { preferences.allow(stage.currentLocation.folder) }

        let service = ScreenshotService(
            preferences: preferences,
            watcher: watcher,
            readLocation: { stage.currentLocation },
            listDirectory: { try stage.list($0) },
            classify: { stage.classify($0) },
            probe: { _ in stage.access },
            trashItem: { try stage.trash($0) },
            schedule: { _, work in work() },
            now: { clock }
        )
        service.onCapture = { box.append($0) }
        return Rig(
            service: service,
            preferences: preferences,
            watcher: watcher,
            stage: stage,
            defaults: defaults,
            suiteName: suiteName,
            captures: { box.all }
        )
    }

    private static func capture(_ name: String) -> ScreenshotClassifier.Verdict {
        .screenshot(CapturedScreenshot(
            url: URL(fileURLWithPath: "/fixtures/Desktop/\(name)"),
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            pixelWidth: 100,
            pixelHeight: 80
        ))
    }

    /// The scan hops off the main actor and back.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Copying

    /// The feature, end to end: a screenshot lands and is offered once. Twice
    /// would put two entries in the clipboard history and raise two popups for
    /// one press of the shutter.
    @Test
    func aScreenshotIsAnnouncedExactlyOnce() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.stage("shot.png", verdict: Self.capture("shot.png"), at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()
        rig.watcher.fire(.changed)
        await settle()

        #expect(rig.captures().count == 1)
        #expect(rig.captures().first?.url.lastPathComponent == "shot.png")
    }

    /// The safety property. Saving a document to your Desktop must never put it
    /// on your clipboard, no matter how new the file is.
    @Test
    func aFileThatIsNotAScreenshotIsNeverAnnounced() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.stage("invoice.png", verdict: .notAScreenshot, at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()
        rig.watcher.fire(.changed)
        await settle()

        #expect(rig.captures().isEmpty)
    }

    /// A large screenshot turns up before it is finished being written. It has
    /// to be looked at again — and still announced only once when it settles.
    @Test
    func aFileThatIsNotReadyYetIsRetriedAndThenAnnouncedOnce() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.stage("big.png", verdict: .unfinished, at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()
        rig.watcher.fire(.changed)
        await settle()
        #expect(rig.captures().isEmpty)

        rig.stage.resolve("big.png", to: Self.capture("big.png"))
        rig.watcher.fire(.changed)
        await settle()

        #expect(rig.captures().count == 1)
    }

    /// And the retrying has to stop. A file that never becomes a screenshot
    /// must be dropped rather than re-read for the rest of the session.
    @Test
    func aFileThatNeverSettlesIsDroppedRatherThanRetriedForever() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.stage("never.png", verdict: .unfinished, at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()

        #expect(rig.captures().isEmpty)
        // One first look plus the ladder, and then it stops.
        #expect(rig.stage.classifyCount <= ScreenshotScanPolicy.retryLadder.count + 1)
    }

    // MARK: - Permission

    /// The rule that keeps a background app from throwing a folder dialog at
    /// someone during login: nothing is opened until the folder has been
    /// allowed through the button in Settings.
    @Test
    func aFolderTheUserHasNotAllowedIsNeverOpened() async throws {
        guard let rig = Self.makeRig(allowingFolder: false) else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }

        rig.service.start()
        await settle()

        #expect(rig.watcher.isArmed == false)
        #expect(rig.service.access == .unknown)
    }

    /// And once it has been allowed, the watch starts without another prompt.
    @Test
    func allowingTheFolderStartsTheWatch() async throws {
        guard let rig = Self.makeRig(allowingFolder: false) else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.service.start()
        await settle()

        rig.service.requestAccess()
        await settle()

        #expect(rig.service.access == .allowed)
        #expect(rig.watcher.isArmed)
        #expect(rig.preferences.isAllowed(rig.stage.currentLocation.folder))
    }

    /// Being sent to the wrong System Settings pane is how a user concludes the
    /// app is broken: NotchHub is already ticked under Full Disk Access, or not
    /// listed there at all. Folder access lives under Files and Folders.
    @Test
    func aDeniedFolderPointsAtFilesAndFoldersNotFullDiskAccess() async throws {
        guard let rig = Self.makeRig(allowingFolder: false) else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.access = .denied
        rig.service.start()

        rig.service.requestAccess()
        await settle()

        #expect(rig.service.access == .denied)
        let message = try #require(rig.service.lastError)
        #expect(message.contains("Files and Folders"))
        #expect(message.contains("Full Disk Access") == false)
        #expect(rig.watcher.isArmed == false)
    }

    // MARK: - Lifecycle

    /// Switching the feature off has to switch the watching off, not just hide
    /// a row — the same rule the module toggles obey.
    @Test
    func stoppingTakesTheWatchDown() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.service.start()
        await settle()
        #expect(rig.watcher.isArmed)

        rig.service.stop()

        #expect(rig.watcher.isArmed == false)
        #expect(rig.watcher.stopCount >= 1)
    }

    /// Changing the save location in System Settings tells nobody, so the
    /// service re-reads it — and must re-arm on the new folder rather than
    /// keep watching the old one.
    @Test
    func changingTheSaveLocationReArmsOnTheNewFolder() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.service.start()
        await settle()

        let moved = URL(fileURLWithPath: "/fixtures/Downloads", isDirectory: true)
        rig.preferences.allow(moved)
        rig.stage.move(to: moved)
        rig.service.refresh()
        await settle()

        #expect(rig.watcher.armed.last == moved)
        #expect(rig.service.folderName == "Downloads")
    }

    /// A folder that disappears must not leave a watch pinned to an inode that
    /// no longer exists.
    @Test
    func aVanishedFolderDropsTheWatch() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.service.start()
        await settle()

        rig.watcher.fire(.vanished)
        await settle()

        #expect(rig.watcher.isArmed == false)
    }

    // MARK: - The file on disk

    /// The default has to leave the user's files exactly where they were.
    @Test
    func theFileIsLeftAloneUnlessTrashingIsSwitchedOn() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.stage.stage("shot.png", verdict: Self.capture("shot.png"), at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()
        rig.watcher.fire(.changed)
        await settle()

        #expect(rig.preferences.trashAfterCopying == false)
        #expect(rig.stage.trashedFiles.isEmpty)
    }

    /// And when it is switched on, the copy happens first. Trashing a file
    /// before its picture is safely on the pasteboard would lose the shot.
    @Test
    func trashingHappensOnlyAfterTheCopyHasBeenHandedOver() async throws {
        guard let rig = Self.makeRig() else { return }
        defer { rig.service.stop(); rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        rig.preferences.trashAfterCopying = true
        rig.service.onCapture = { [stage = rig.stage] _ in stage.note("copied") }
        rig.stage.stage("shot.png", verdict: Self.capture("shot.png"), at: Self.clock.addingTimeInterval(1))

        rig.service.start()
        await settle()
        rig.watcher.fire(.changed)
        await settle()

        let ordered = rig.stage.log.filter { $0 == "copied" || $0.hasPrefix("trash:") }
        #expect(ordered == ["copied", "trash:shot.png"])
        #expect(rig.stage.trashedFiles.count == 1)
    }
}

/// The one rule about what a copied screenshot is allowed to leave behind.
@Suite("Screenshot clipboard policy")
struct ScreenshotClipboardPolicyTests {

    /// Hiding the Clipboard module is the user asking NotchHub not to keep or
    /// show their clipboard, so that is the half that switches off.
    @Test
    func nothingIsRememberedWhileTheClipboardModuleIsHidden() {
        #expect(ScreenshotService.shouldRemember(clipboardModuleVisible: false) == false)
    }

    /// With the module visible the screenshot behaves like any other copy —
    /// history entry, popup, drag-out.
    @Test
    func aScreenshotIsRememberedWhileTheClipboardModuleIsVisible() {
        #expect(ScreenshotService.shouldRemember(clipboardModuleVisible: true))
    }
}
