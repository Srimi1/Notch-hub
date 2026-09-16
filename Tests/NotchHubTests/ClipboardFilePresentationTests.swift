import AppKit
import Foundation
import Testing
@testable import NotchHub

/// File icons and sizes resolve off the main thread at ingest, so a slow file
/// can never stall the popup — and with it the pasteboard sampler. These pin
/// the async arrival, the lifecycle (the cache drops with its clips), and the
/// prompt-avoidance boundary the size resolution obeys.
@Suite("Clipboard file presentation")
@MainActor
struct ClipboardFilePresentationTests {

    private static func makeIsolated() -> (ClipboardService, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchHubTests." + UUID().uuidString))
        return (ClipboardService(pasteboard: pasteboard), pasteboard)
    }

    /// Async arrival has no exact tick to wait on, so poll a condition with a
    /// generous budget instead of sleeping blindly. The fixtures are local
    /// files that resolve in milliseconds.
    private static func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func fixtureFile(bytes: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchhub-presentation-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// A file clip resolves both halves of its presentation: the size lands in
    /// `fileSizes` and the icon lands in `thumbnails` (unless a QuickLook
    /// preview got there first, which only also satisfies the popup).
    @Test
    func aFileClipResolvesItsIconAndSize() async throws {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        let url = try Self.fixtureFile(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: url) }

        clipboard.add(.file(url))
        let id = try #require(clipboard.clips.first?.id)

        let resolved = await Self.waitFor {
            clipboard.fileSizes[id] == 4096 && clipboard.thumbnails[id] != nil
        }
        #expect(resolved)
        #expect(clipboard.fileSizes[id] == 4096)
    }

    /// Sizes drop with their clips: clearing must not leave file sizes behind
    /// any more than thumbnails.
    @Test
    func clearingDropsResolvedSizes() async throws {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        let url = try Self.fixtureFile(bytes: 16)
        defer { try? FileManager.default.removeItem(at: url) }

        clipboard.add(.file(url))
        let id = try #require(clipboard.clips.first?.id)
        _ = await Self.waitFor { clipboard.fileSizes[id] != nil }

        clipboard.clear()

        #expect(clipboard.clips.isEmpty)
        #expect(clipboard.thumbnails.isEmpty)
        #expect(clipboard.fileSizes.isEmpty)
    }

    /// Trimming prunes sizes alongside thumbnails. The subset holds at every
    /// instant — a size landing for a trimmed clip is dropped, never stored —
    /// so this asserts the invariant after every id has had its chance.
    @Test
    func trimmingPrunesSizesAlongsideThumbnails() async throws {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for _ in 0 ..< 13 {
            let url = try Self.fixtureFile(bytes: 8)
            urls.append(url)
            clipboard.add(.file(url))
        }

        #expect(clipboard.clips.count == 12)
        let live = Set(clipboard.clips.map(\.id))
        let settled = await Self.waitFor { clipboard.fileSizes.count == live.count }
        #expect(settled)
        #expect(Set(clipboard.fileSizes.keys) == live)
    }

    /// A file that does not exist resolves no size (and crashes nothing). The
    /// icon still arrives — the workspace answers a generic document icon for
    /// unknown paths — so the popup degrades to name, type, and icon.
    @Test
    func aMissingFileResolvesAnIconButNoSize() async throws {
        let (clipboard, pasteboard) = Self.makeIsolated()
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchhub-missing-\(UUID().uuidString)/ghost.bin")

        clipboard.add(.file(url))
        let id = try #require(clipboard.clips.first?.id)

        let iconArrived = await Self.waitFor { clipboard.thumbnails[id] != nil }
        #expect(iconArrived)
        // A missing path fails fast, so anything still absent after the settle
        // window is stably absent rather than merely slow.
        _ = await Self.waitFor(timeout: 0.5) { clipboard.fileSizes[id] != nil }
        #expect(clipboard.fileSizes[id] == nil)
    }

    /// The prompt-avoidance boundary the size resolution obeys: protected
    /// folders without the grant stay unread, with the grant everything reads,
    /// unguarded paths always read, and a sibling prefix (`Desktop2`) is not a
    /// child of the guarded folder. Pure and synchronous — no timing involved.
    @Test(
        "Prompt-avoidance boundary",
        arguments: [
            ("/Users/x/Desktop/report.pdf", false, false),
            ("/Users/x/Desktop", false, false),
            ("/Users/x/Desktop/report.pdf", true, true),
            ("/Users/x/Documents/notes.txt", false, false),
            ("/Users/x/Downloads/a.zip", false, false),
            ("/Users/x/Library/Mobile Documents/i.pages", false, false),
            ("/tmp/work.bin", false, true),
            ("/Users/x/Desktop2/report.pdf", false, true),
            ("/Users/x/Movies/clip.mov", false, true)
        ]
    )
    func promptAvoidanceBoundary(path: String, granted: Bool, expected: Bool) {
        let url = URL(fileURLWithPath: path)
        #expect(ClipboardService.isReadableWithoutPrompting(
            url,
            fullDiskAccessGranted: granted,
            home: "/Users/x"
        ) == expected)
    }
}
