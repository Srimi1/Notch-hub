import AppKit
import Foundation
import Testing
@testable import NotchHub

/// Restoring a clip used to rewrite the history under the pointer, so the next
/// click in the same spot landed on a different entry. These pin the order and
/// identity guarantees the clipboard UI relies on.
@Suite("Clipboard history")
@MainActor
struct ClipboardServiceTests {

    /// A private pasteboard per test. Running the suite while NotchHub itself
    /// is running used to hand the app's poller these fixtures as if the user
    /// had copied them, so "first" and "alpha" turned up in real documents.
    private static func makeIsolated() -> (ClipboardService, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchHubTests." + UUID().uuidString))
        return (ClipboardService(pasteboard: pasteboard), pasteboard)
    }

    /// Picking an entry must leave the list exactly where it was — same order,
    /// same ids — or a second click targets whatever slid under the cursor.
    @Test
    func restoringAClipLeavesTheHistoryOrderAndIdentityAlone() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        clipboard.add(.text("first"))
        clipboard.add(.text("second"))
        clipboard.add(.text("third"))
        let before = clipboard.clips

        clipboard.copy(before[2])

        #expect(clipboard.clips.map(\.id) == before.map(\.id))
        #expect(clipboard.clips.map(\.preview) == ["third", "second", "first"])
    }

    /// The restored clip is what actually reaches the pasteboard — the point of
    /// the whole gesture.
    @Test
    func restoringAClipWritesThatClipToThePasteboard() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        clipboard.add(.text("alpha"))
        clipboard.add(.text("omega"))

        clipboard.copy(clipboard.clips[1])

        #expect(pasteboard.string(forType: .string) == "alpha")
    }

    /// The suite must never touch the clipboard the user is actually using.
    @Test
    func restoringAClipLeavesTheGeneralPasteboardAlone() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        let before = NSPasteboard.general.changeCount

        clipboard.add(.text("fixture that must not escape"))
        clipboard.copy(clipboard.clips[0])

        #expect(NSPasteboard.general.changeCount == before)
    }

    /// Copying the same content again collapses onto one entry rather than
    /// stacking duplicates.
    @Test
    func recopyingTheSameContentDoesNotDuplicateTheEntry() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        clipboard.add(.text("repeat"))
        clipboard.add(.text("other"))
        clipboard.add(.text("repeat"))

        #expect(clipboard.clips.count == 2)
        #expect(clipboard.clips[0].preview == "repeat")
    }

    /// A replaced clip must take its thumbnail with it; the dictionary is keyed
    /// by clip id, so a stale key is a leak nothing can ever render or clear.
    @Test
    func replacingAClipDropsItsThumbnail() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        clipboard.add(.text("shared"))
        let stale = clipboard.clips[0].id

        clipboard.add(.text("shared"))

        #expect(clipboard.thumbnails[stale] == nil)
    }

    /// History is bounded, and trimming prunes thumbnails alongside the clips.
    @Test
    func historyStopsAtTheLimitAndPrunesTrimmedThumbnails() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        for index in 0 ..< 20 { clipboard.add(.text("clip \(index)")) }

        #expect(clipboard.clips.count == 12)
        #expect(clipboard.clips[0].preview == "clip 19")
        let live = Set(clipboard.clips.map(\.id))
        #expect(clipboard.thumbnails.keys.allSatisfy { live.contains($0) })
    }

    /// `clearContents()` advances the change counter before the content that
    /// follows it exists. Treating that generation as seen dropped the copy:
    /// it never entered the history, and the next paste from the notch was
    /// whatever the user had copied before.
    @Test
    func aCounterBumpWithNothingBehindItIsLookedAtAgain() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        clipboard.sample()
        #expect(clipboard.clips.isEmpty)

        pasteboard.setString("landed late", forType: .string)
        clipboard.sample()

        #expect(clipboard.clips.map(\.preview) == ["landed late"])
    }

    /// Retrying cannot go on forever, or an empty pasteboard is re-read four
    /// times a second for the rest of the session.
    @Test
    func anEmptyPasteboardIsWrittenOffAfterTheRetryLimit() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        for _ in 0 ..< ClipboardService.maximumSampleRetries { clipboard.sample() }

        // Written off — and a real copy afterwards is still picked up.
        pasteboard.clearContents()
        pasteboard.setString("real", forType: .string)
        clipboard.sample()

        #expect(clipboard.clips.map(\.preview) == ["real"])
    }

    /// Writing to the pasteboard is several calls, and the privacy marker does
    /// not necessarily arrive with the content. Sampling mid-write could read
    /// a password before the marker saying not to.
    @Test
    func concealedContentIsDroppedEvenWhenItWasReadable() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: concealed)
        clipboard.sample()

        #expect(clipboard.clips.isEmpty)
    }

    /// Copying several files in Finder is one gesture. Adding them one at a
    /// time reversed the selection and raised the popup once per file.
    @Test
    func aMultiFileCopyKeepsItsOrderAndAnnouncesItselfOnce() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        var announcements = 0
        clipboard.onCopy = { _ in announcements += 1 }

        clipboard.add(contentsOf: [
            .file(URL(fileURLWithPath: "/tmp/a.png")),
            .file(URL(fileURLWithPath: "/tmp/b.png")),
            .file(URL(fileURLWithPath: "/tmp/c.png"))
        ])

        #expect(clipboard.clips.map(\.preview) == ["a.png", "b.png", "c.png"])
        #expect(announcements == 1)
    }

    /// Clearing drops both sides of the state together.
    @Test
    func clearingEmptiesClipsAndThumbnails() {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        clipboard.add(.text("gone"))

        clipboard.clear()

        #expect(clipboard.clips.isEmpty)
        #expect(clipboard.thumbnails.isEmpty)
    }
}

/// Copied images are shown at 44 points and were being kept at whatever size
/// they arrived at. These pin the bound.
@Suite("Clipboard previews")
@MainActor
struct ClipboardPreviewTests {

    private static func makeIsolated() -> (ClipboardService, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchHubTests." + UUID().uuidString))
        return (ClipboardService(pasteboard: pasteboard), pasteboard)
    }

    /// A solid bitmap big enough to be a Retina screenshot.
    private static func png(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Could not build a PNG fixture")
            return Data()
        }
        return data
    }

    /// The bug this pins: image clips kept `NSImage(data:)` — the picture at
    /// full resolution, decoded — as their "thumbnail", while file clips had
    /// always asked QuickLook for 72 points. Harmless while people only ⌘C'd
    /// the occasional image; with screenshots copying themselves, twelve
    /// Retina captures in history left NotchHub holding hundreds of megabytes
    /// for previews drawn 44 points wide.
    @Test
    func anImageClipKeepsABoundedPreviewRatherThanTheWholeBitmap() throws {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        let data = Self.png(width: 2000, height: 1500)

        clipboard.add(.image(data))

        let clip = try #require(clipboard.clips.first)
        let thumbnail = try #require(clipboard.thumbnails[clip.id])
        let longestEdge = max(thumbnail.size.width, thumbnail.size.height)
        #expect(longestEdge <= CGFloat(ClipboardService.thumbnailMaximumPixels))
        #expect(longestEdge > 0)
    }

    /// Downscaling must not change the shape of the picture.
    @Test
    func aBoundedPreviewKeepsTheOriginalAspectRatio() throws {
        let data = Self.png(width: 1600, height: 800)

        let thumbnail = try #require(ClipboardService.thumbnail(from: data))
        let ratio = thumbnail.size.width / max(thumbnail.size.height, 1)

        #expect(abs(ratio - 2) < 0.05)
    }

    /// Bytes that are not a picture must come back as no preview rather than
    /// throwing out through the history insert.
    @Test
    func contentThatIsNotAnImageProducesNoPreview() {
        #expect(ClipboardService.thumbnail(from: Data("not a picture".utf8)) == nil)
    }
}
