import Foundation
import Testing
@testable import NotchHub

/// The whole feature rests on one piece of metadata macOS writes and does not
/// document, so these use the exact bytes taken off a real screenshot rather
/// than a plist this test encoded itself.
@Suite("Screenshot metadata")
struct ScreenshotXattrTests {

    /// `com.apple.metadata:kMDItemIsScreenCapture`, copied byte for byte off
    /// `~/Desktop/Screenshot 2026-08-26 at 1.47.01 PM.png` on macOS 26.6.
    private static let realMarker = Data(hex:
        "62706C697374303009080000000000000101000000000000000100000000000000000000000000000009")

    /// The same attribute encoding `false` rather than `true`.
    private static let falseMarker = Data(hex:
        "62706C697374303008080000000000000101000000000000000100000000000000000000000000000009")

    /// `com.apple.metadata:kMDItemScreenCaptureType` from the same file.
    private static let realType = Data(hex:
        "62706C697374303057646973706C6179080000000000000101000000000000000100000000000000000000"
            + "000000000010")

    /// The bytes macOS actually writes have to decode, or nothing is ever
    /// recognised as a screenshot and the feature is inert.
    @Test
    func theMetadataMacOSWritesDecodesAsAScreenshot() {
        #expect(ScreenshotXattr.isScreenCapture(Self.realMarker))
    }

    /// The bug this guards: treating "the attribute exists" as "it says yes".
    /// Presence and truth are different facts, and only one of them means the
    /// file may be copied.
    @Test
    func anAttributeSayingFalseIsNotAScreenshot() {
        #expect(ScreenshotXattr.isScreenCapture(Self.falseMarker) == false)
    }

    /// A file with no marker at all is the overwhelmingly common case — every
    /// document the user ever saves to their Desktop — and must never be read.
    @Test
    func aFileWithNoMarkerIsNotAScreenshot() {
        #expect(ScreenshotXattr.isScreenCapture(atPath: "/anything", read: { _, _ in nil }) == false)
    }

    /// Empty bytes must be rejected before the decoder sees them.
    @Test
    func emptyMetadataIsNotAScreenshot() {
        #expect(ScreenshotXattr.isScreenCapture(Data()) == false)
    }

    /// A truncated plist has to come back as "not a screenshot" rather than
    /// throwing out through the classifier and taking the scan with it.
    @Test
    func truncatedMetadataIsRejectedRatherThanThrowing() {
        #expect(ScreenshotXattr.isScreenCapture(Self.realMarker.prefix(12)) == false)
    }

    /// Random bytes are what a corrupted or hostile attribute looks like.
    @Test
    func garbageMetadataIsNotAScreenshot() {
        #expect(ScreenshotXattr.isScreenCapture(Data([0xFF, 0x00, 0x42, 0x13])) == false)
    }

    /// The capture type is diagnostics only, but decoding it proves the reader
    /// handles a string payload as well as a boolean one.
    @Test
    func theCaptureTypeDecodesToTheKindOfShotItWas() {
        let type = ScreenshotXattr.captureType(atPath: "/anything", read: { _, _ in Self.realType })

        #expect(type == "display")
    }

    /// The path the classifier actually calls has to agree with the raw-bytes
    /// path, or the tests above would be pinning an unused function.
    @Test
    func thePathReaderAgreesWithTheBytesReader() {
        let verdict = ScreenshotXattr.isScreenCapture(
            atPath: "/anything",
            read: { _, name in name == ScreenshotXattr.isScreenCaptureName ? Self.realMarker : nil }
        )

        #expect(verdict)
    }
}

private extension Data {
    /// Byte fixtures read better as hex than as a 42-element array literal.
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
