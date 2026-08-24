import Foundation
import Testing
@testable import NotchHub

/// The HUD gets two lines to describe a clip; these pin what goes in them.
@Suite("HUD clip details")
struct HudClipDetailsTests {

    private func clip(_ kind: ClipboardService.Clip.Kind) -> ClipboardService.Clip {
        ClipboardService.Clip(id: UUID(), kind: kind, date: .now)
    }

    @Test
    func aFileShowsNameSizeAndSystemTypeName() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let details = HudClipDetails.make(for: clip(.file(url)), fileSize: { _ in 1_234_567 })

        #expect(details.title == "report.pdf")
        let subtitle = details.subtitle ?? ""
        #expect(subtitle.contains("MB"))
        #expect(subtitle.contains("·"))
    }

    /// A file whose size cannot be read (gone, or a permissions edge) still gets
    /// its type — the HUD degrades, it does not vanish.
    @Test
    func anUnreadableFileSizeDegradesToTypeOnly() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let details = HudClipDetails.make(for: clip(.file(url)), fileSize: { _ in nil })

        #expect(details.title == "report.pdf")
        #expect(details.subtitle?.contains("MB") == false)
        #expect(details.subtitle?.isEmpty == false)
    }

    @Test
    func anUnknownExtensionFallsBackToTheBareExtension() {
        let url = URL(fileURLWithPath: "/tmp/data.zqx9")
        let details = HudClipDetails.make(for: clip(.file(url)), fileSize: { _ in 10 })

        #expect(details.title == "data.zqx9")
        #expect(details.subtitle?.contains("ZQX9") == true)
    }

    @Test
    func textCollapsesToOneTrimmedLineAndIsCapped() {
        let details = HudClipDetails.make(for: clip(.text("  hello\nworld  ")))
        #expect(details.title == "hello world")
        #expect(details.subtitle == nil)

        let long = HudClipDetails.make(for: clip(.text(String(repeating: "a", count: 300))))
        #expect(long.title.count <= 81)
        #expect(long.title.hasSuffix("…"))
    }

    @Test
    func emptyTextIsLabeledRatherThanBlank() {
        let details = HudClipDetails.make(for: clip(.text("   \n  ")))
        #expect(details.title == "Empty text")
    }

    @Test
    func imagesGetAStableLabel() {
        let details = HudClipDetails.make(for: clip(.image(Data([0x01]))))
        #expect(details.title == "Image")
        #expect(details.subtitle != nil)
    }
}
