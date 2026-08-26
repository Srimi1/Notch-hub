import Foundation
import Testing
@testable import NotchHub

/// `screencapture` reads where to save from a defaults domain anyone can write
/// and macOS never announces. Everything here is the resolver's contract with
/// that string.
@Suite("Screenshot save location")
struct ScreenshotLocationTests {

    private static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    /// Unset is not the same as empty. `screencapture` with no `location`
    /// writes to the Desktop; resolving that to an empty path would have the
    /// watcher open the process's working directory instead.
    @Test
    func anUnsetLocationIsTheDesktop() {
        let resolved = ScreenshotLocation.resolve(location: nil, type: nil, home: Self.home)

        #expect(resolved.folder.path == "/Users/tester/Desktop")
        #expect(resolved.format == .png)
    }

    /// An empty string is what a cleared preference leaves behind, and it means
    /// the same thing as never having set one.
    @Test
    func anEmptyLocationIsTheDesktop() {
        let resolved = ScreenshotLocation.resolve(location: "   ", type: nil, home: Self.home)

        #expect(resolved.folder.path == "/Users/tester/Desktop")
    }

    /// The bug this pins: a raw `~/Shots` handed to `open(2)` does not resolve.
    /// It creates a directory literally named `~` beside the process, and the
    /// watcher then sits on an empty folder forever.
    @Test
    func aTildeLocationIsExpandedAgainstTheHomeDirectory() {
        let resolved = ScreenshotLocation.resolve(location: "~/Shots", type: nil, home: Self.home)

        #expect(resolved.folder.path == "/Users/tester/Shots")
    }

    /// A bare tilde is a legal value and means the home directory itself.
    @Test
    func abareTildeIsTheHomeDirectory() {
        let resolved = ScreenshotLocation.resolve(location: "~", type: nil, home: Self.home)

        #expect(resolved.folder.path == "/Users/tester")
    }

    /// System Settings has been seen storing the location as a file URL rather
    /// than a path, and `URL(fileURLWithPath:)` on that string would produce a
    /// folder called `file:`.
    @Test
    func aFileURLLocationIsParsedAsAURL() {
        let resolved = ScreenshotLocation.resolve(
            location: "file:///Users/tester/Pictures/Shots", type: nil, home: Self.home
        )

        #expect(resolved.folder.path == "/Users/tester/Pictures/Shots")
    }

    /// A trailing slash must not make a second, different folder identity, or
    /// the permission grant recorded for one spelling misses the other.
    @Test
    func aTrailingSlashIsTheSameFolder() {
        let withSlash = ScreenshotLocation.resolve(location: "/tmp/shots/", type: nil, home: Self.home)
        let without = ScreenshotLocation.resolve(location: "/tmp/shots", type: nil, home: Self.home)

        #expect(withSlash.folder == without.folder)
    }

    /// A relative path means nothing to a background app whose working
    /// directory is not the user's, so it is treated as unset rather than
    /// resolved against somewhere arbitrary.
    @Test
    func aRelativeLocationFallsBackToTheDesktop() {
        let resolved = ScreenshotLocation.resolve(location: "Shots", type: nil, home: Self.home)

        #expect(resolved.folder.path == "/Users/tester/Desktop")
    }

    /// PDF captures are a real setting. They carry no bitmap, so the module has
    /// to be able to say why nothing is being copied instead of looking broken.
    @Test
    func aPDFFormatIsNotAnImage() {
        let resolved = ScreenshotLocation.resolve(location: nil, type: "pdf", home: Self.home)

        #expect(resolved.format == .pdf)
        #expect(resolved.format.isImage == false)
        #expect(ScreenshotService.formatNote(for: resolved.format) != nil)
    }

    /// Every bitmap format `screencapture` writes has to survive the round trip
    /// as an image, or the feature silently stops for anyone who changed it.
    @Test
    func everyBitmapFormatIsAnImage() {
        for raw in ["png", "jpg", "jpeg", "tiff", "heic", "gif", "bmp", "PNG"] {
            let format = ScreenshotFormat.named(raw)
            #expect(format.isImage, "expected \(raw) to be treated as an image")
            #expect(ScreenshotService.formatNote(for: format) == nil)
        }
    }

    /// An unrecognised value must not crash the resolver — the domain is a file
    /// anything running as the user can write.
    @Test
    func anUnknownFormatIsCarriedThroughWithoutCrashing() {
        let format = ScreenshotFormat.named("wibble")

        #expect(format == .other("wibble"))
        #expect(format.isImage == false)
        #expect(format.displayName == "WIBBLE")
    }
}
