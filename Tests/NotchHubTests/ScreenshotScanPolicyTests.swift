import Foundation
import Testing
@testable import NotchHub

/// Which files a scan looks at. Everything here is pure, so none of it touches
/// a real folder — least of all the Desktop.
@Suite("Screenshot scan policy")
struct ScreenshotScanPolicyTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func entry(_ name: String, secondsAfterEpoch: TimeInterval) -> ScreenshotScanPolicy.Entry {
        ScreenshotScanPolicy.Entry(
            url: URL(fileURLWithPath: "/fixtures/\(name)"),
            modified: epoch.addingTimeInterval(secondsAfterEpoch),
            size: 1024
        )
    }

    /// The bug this pins: starting the watcher with a cutoff of
    /// `.distantPast` would treat every screenshot already sitting on the
    /// Desktop as new and copy the user's whole archive to the clipboard, one
    /// file at a time. Only files modified since the last look count.
    @Test
    func filesOlderThanTheCutoffAreNeverCandidates() {
        let entries = [
            Self.entry("old.png", secondsAfterEpoch: -60),
            Self.entry("new.png", secondsAfterEpoch: 60)
        ]

        let candidates = ScreenshotScanPolicy.candidates(in: entries, newerThan: Self.epoch)

        #expect(candidates.map(\.url.lastPathComponent) == ["new.png"])
    }

    /// Screen recordings are `.mov` and macOS tags them too, so the extension
    /// filter is what keeps a video off the clipboard — before any file is
    /// opened, not after.
    @Test
    func screenRecordingsAreFilteredBeforeAnyFileIsOpened() {
        let entries = [
            Self.entry("recording.mov", secondsAfterEpoch: 60),
            Self.entry("shot.png", secondsAfterEpoch: 61)
        ]

        let candidates = ScreenshotScanPolicy.candidates(in: entries, newerThan: Self.epoch)

        #expect(candidates.map(\.url.lastPathComponent) == ["shot.png"])
    }

    /// A screenshot already copied must not be copied again when a second
    /// directory event arrives for the same write.
    @Test
    func alreadyHandledFilesAreNotOfferedTwice() {
        let entries = [Self.entry("shot.png", secondsAfterEpoch: 60)]

        let candidates = ScreenshotScanPolicy.candidates(
            in: entries, newerThan: Self.epoch, excluding: ["/fixtures/shot.png"]
        )

        #expect(candidates.isEmpty)
    }

    /// When the cap bites, the shot the user just took is the one they are
    /// waiting to paste — so candidates come back newest first.
    @Test
    func candidatesComeBackNewestFirst() {
        let entries = [
            Self.entry("first.png", secondsAfterEpoch: 10),
            Self.entry("third.png", secondsAfterEpoch: 30),
            Self.entry("second.png", secondsAfterEpoch: 20)
        ]

        let candidates = ScreenshotScanPolicy.candidates(in: entries, newerThan: Self.epoch)

        #expect(candidates.map(\.url.lastPathComponent) == ["third.png", "second.png", "first.png"])
    }

    /// Unpacking an archive onto the Desktop drops hundreds of files at once.
    /// None are screenshots, each costs a metadata read, and the watch queue
    /// must not disappear into that.
    @Test
    func aFloodOfFilesIsCappedPerScan() {
        let entries = (0 ..< 200).map { Self.entry("file\($0).png", secondsAfterEpoch: Double($0 + 1)) }

        let candidates = ScreenshotScanPolicy.candidates(in: entries, newerThan: Self.epoch)

        #expect(candidates.count == ScreenshotScanPolicy.maximumCandidatesPerScan)
    }

    /// The bug this pins: advancing the cutoff to the newest file's timestamp
    /// lets a file dated in the future — a backup restore, a wrong clock, an
    /// SMB share — push the cutoff past every real screenshot and switch the
    /// feature off silently for the rest of the session. The cutoff only ever
    /// moves to when the scan began.
    @Test
    func aFileDatedInTheFutureCannotPoisonTheCutoff() {
        let started = Self.epoch.addingTimeInterval(5)

        let next = ScreenshotScanPolicy.nextCutoff(after: Self.epoch, scanStartedAt: started)

        #expect(next == started)
    }

    /// Two scans finishing out of order must not walk the cutoff backwards and
    /// re-offer files that were already handled.
    @Test
    func theCutoffNeverMovesBackwards() {
        let earlier = Self.epoch.addingTimeInterval(-30)

        let next = ScreenshotScanPolicy.nextCutoff(after: Self.epoch, scanStartedAt: earlier)

        #expect(next == Self.epoch)
    }

    /// The ladder has to cover the time a large multi-display PNG takes to
    /// finish being written, or big screenshots are dropped as "not ready".
    @Test
    func theRetryLadderCoversSeveralSecondsOfWriting() {
        let total = (0...).lazy
            .map(ScreenshotScanPolicy.retryDelay(attempt:))
            .prefix { $0 != nil }
            .compactMap { $0 }
            .reduce(0, +)

        #expect(total >= 5)
    }

    /// And it has to end. A file that never becomes a screenshot must be
    /// dropped rather than re-examined for the rest of the session.
    @Test
    func theRetryLadderRunsOut() {
        #expect(ScreenshotScanPolicy.retryDelay(attempt: ScreenshotScanPolicy.retryLadder.count) == nil)
        #expect(ScreenshotScanPolicy.retryDelay(attempt: -1) == nil)
    }

    /// The handled list is what stops a double copy, and it has to stay bounded
    /// or a long session grows it without limit.
    @Test
    func theHandledListRemembersRecentPathsAndForgetsOldOnes() {
        var handled: [String] = []
        for index in 0 ..< (ScreenshotScanPolicy.handledMemory + 10) {
            handled = ScreenshotScanPolicy.remembering("/fixtures/shot\(index).png", in: handled)
        }

        #expect(handled.count == ScreenshotScanPolicy.handledMemory)
        #expect(handled.contains("/fixtures/shot41.png"))
        #expect(handled.contains("/fixtures/shot0.png") == false)
    }
}
