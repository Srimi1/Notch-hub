import AppKit
import Foundation
import Testing
@testable import NotchHub

/// What is allowed to reach the pasteboard. The cheap checks have to come
/// first, so a file is only ever opened once it has passed all of them.
@Suite("Screenshot classification")
struct ScreenshotClassifierTests {

    /// An exact-pixel bitmap of noise. Noise, not a flat colour, so the PNG is
    /// big enough that truncating it actually truncates image data — a solid
    /// fill compresses to almost nothing and would still decode.
    private static func png(width: Int, height: Int) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let plane = rep.bitmapData else {
            Issue.record("Could not build a bitmap fixture")
            return Data()
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for offset in 0 ..< (rep.bytesPerRow * height) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            plane[offset] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Could not encode a PNG fixture")
            return Data()
        }
        return data
    }

    private static func classify(
        _ name: String,
        data: Data,
        tagged: Bool = true,
        size: Int? = nil
    ) -> ScreenshotClassifier.Verdict {
        ScreenshotClassifier.classify(
            url: URL(fileURLWithPath: "/fixtures/\(name)"),
            isScreenCapture: { _ in tagged },
            readData: { _ in data },
            fileSize: { _ in size ?? data.count }
        )
    }

    /// The happy path, and the guarantee the pasteboard write depends on:
    /// pixels, and their real size.
    @Test
    func aTaggedCompleteImageBecomesACapture() {
        let data = Self.png(width: 120, height: 90)

        guard case .screenshot(let capture) = Self.classify("shot.png", data: data) else {
            Issue.record("expected a screenshot")
            return
        }

        #expect(capture.pixelWidth == 120)
        #expect(capture.pixelHeight == 90)
        #expect(capture.pngData.isEmpty == false)
    }

    /// A PNG screenshot is the default case, so its bytes go through
    /// untouched — recompressing every capture would cost time and quality for
    /// nothing.
    @Test
    func aPNGIsPassedThroughWithoutRecompression() {
        let data = Self.png(width: 60, height: 40)

        guard case .screenshot(let capture) = Self.classify("shot.png", data: data) else {
            Issue.record("expected a screenshot")
            return
        }

        #expect(capture.pngData == data)
    }

    /// The safety property, at the level that enforces it: without the marker
    /// macOS writes, the file is not read and not copied.
    @Test
    func anUntaggedFileIsNotAScreenshot() {
        let verdict = Self.classify("invoice.png", data: Self.png(width: 10, height: 10), tagged: false)

        #expect(verdict == .notAScreenshot)
    }

    /// ⌘⇧5 records video. macOS tags recordings too, so the extension is what
    /// keeps a `.mov` off the clipboard — and it is checked before the marker,
    /// so a recording is never even opened.
    @Test
    func aScreenRecordingIsRefusedByItsExtension() {
        let verdict = ScreenshotClassifier.classify(
            url: URL(fileURLWithPath: "/fixtures/recording.mov"),
            isScreenCapture: { _ in Issue.record("a recording must not be opened"); return true },
            readData: { _ in Data() },
            fileSize: { _ in 10 }
        )

        #expect(verdict == .unsupportedFormat)
    }

    /// A PDF capture carries no bitmap. It has to be named as unsupported so
    /// Settings can explain it, rather than silently copying nothing.
    @Test
    func aPDFCaptureIsUnsupportedRatherThanSilentlyIgnored() {
        let verdict = ScreenshotClassifier.classify(
            url: URL(fileURLWithPath: "/fixtures/shot.pdf"),
            isScreenCapture: { _ in true },
            readData: { _ in Data() },
            fileSize: { _ in 10 }
        )

        #expect(verdict == .unsupportedFormat)
    }

    /// The cap is checked from the file's size before anything is read, so an
    /// enormous file is never resident in memory at all.
    @Test
    func anOversizedFileIsRefusedBeforeItIsRead() {
        let verdict = ScreenshotClassifier.classify(
            url: URL(fileURLWithPath: "/fixtures/huge.png"),
            isScreenCapture: { _ in true },
            readData: { _ in Issue.record("an oversized file must not be read"); return Data() },
            fileSize: { _ in ScreenshotClassifier.maximumBytes + 1 }
        )

        #expect(verdict == .tooLarge(bytes: ScreenshotClassifier.maximumBytes + 1))
    }

    /// The bug this pins, and the reason the check is not the obvious one:
    /// a screenshot is seen the instant its file appears, part-written. ImageIO
    /// is no help — `CGImageSourceGetStatus` calls a PNG truncated to a third
    /// "complete", and `CGImageSourceCreateImageAtIndex` decodes it into a
    /// half-grey picture — so without the container check a corrupt image
    /// reaches the clipboard and the real screenshot never does.
    @Test
    func aHalfWrittenImageIsUnfinishedRatherThanCopied() {
        let whole = Self.png(width: 400, height: 300)
        let partial = Data(whole.prefix(whole.count / 3))

        let verdict = Self.classify("growing.png", data: partial, size: partial.count)

        #expect(verdict == .unfinished)
    }

    /// A file still growing between the size check and the read is mid-write,
    /// whatever its bytes look like — the backstop for formats with no trailer
    /// to inspect.
    @Test
    func aFileStillGrowingWhileItIsReadIsUnfinished() {
        let whole = Self.png(width: 80, height: 60)

        let verdict = Self.classify("growing.png", data: whole, size: whole.count + 4096)

        #expect(verdict == .unfinished)
    }

    /// The PNG end marker is the whole check, so it is worth pinning directly.
    @Test
    func completenessIsJudgedByTheContainersEndMarker() {
        let whole = Self.png(width: 40, height: 30)

        #expect(ScreenshotClassifier.isComplete(whole, pathExtension: "png"))
        #expect(ScreenshotClassifier.isComplete(Data(whole.dropLast()), pathExtension: "png") == false)
        #expect(ScreenshotClassifier.isComplete(Data(), pathExtension: "png") == false)
    }

    /// JPEG captures are a supported setting and end differently.
    @Test
    func aJPEGIsJudgedByItsEndOfImageMarker() {
        let complete = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

        #expect(ScreenshotClassifier.isComplete(complete, pathExtension: "jpg"))
        #expect(ScreenshotClassifier.isComplete(Data(complete.dropLast()), pathExtension: "jpeg") == false)
    }

    /// A file that exists but has no bytes yet is the first instant of a write.
    @Test
    func anEmptyFileIsUnfinished() {
        #expect(Self.classify("new.png", data: Data(), size: 0) == .unfinished)
    }
}
