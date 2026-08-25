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

    /// Picking an entry must leave the list exactly where it was — same order,
    /// same ids — or a second click targets whatever slid under the cursor.
    @Test
    func restoringAClipLeavesTheHistoryOrderAndIdentityAlone() {
        let clipboard = ClipboardService()
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
        let clipboard = ClipboardService()
        clipboard.add(.text("alpha"))
        clipboard.add(.text("omega"))

        clipboard.copy(clipboard.clips[1])

        #expect(NSPasteboard.general.string(forType: .string) == "alpha")
    }

    /// Copying the same content again collapses onto one entry rather than
    /// stacking duplicates.
    @Test
    func recopyingTheSameContentDoesNotDuplicateTheEntry() {
        let clipboard = ClipboardService()
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
        let clipboard = ClipboardService()
        clipboard.add(.text("shared"))
        let stale = clipboard.clips[0].id

        clipboard.add(.text("shared"))

        #expect(clipboard.thumbnails[stale] == nil)
    }

    /// History is bounded, and trimming prunes thumbnails alongside the clips.
    @Test
    func historyStopsAtTheLimitAndPrunesTrimmedThumbnails() {
        let clipboard = ClipboardService()
        for index in 0 ..< 20 { clipboard.add(.text("clip \(index)")) }

        #expect(clipboard.clips.count == 12)
        #expect(clipboard.clips[0].preview == "clip 19")
        let live = Set(clipboard.clips.map(\.id))
        #expect(clipboard.thumbnails.keys.allSatisfy { live.contains($0) })
    }

    /// Clearing drops both sides of the state together.
    @Test
    func clearingEmptiesClipsAndThumbnails() {
        let clipboard = ClipboardService()
        clipboard.add(.text("gone"))

        clipboard.clear()

        #expect(clipboard.clips.isEmpty)
        #expect(clipboard.thumbnails.isEmpty)
    }
}
