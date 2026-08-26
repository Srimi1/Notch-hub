import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screenshot that has been read, checked, and is ready for the pasteboard.
///
/// Everything in it is `Sendable`, so it crosses from the watch queue back to
/// the main actor without a box or an unchecked conformance.
struct CapturedScreenshot: Sendable, Equatable {
    var url: URL
    var pngData: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Decides whether a file that just appeared is a screenshot worth copying.
///
/// The order matters: the cheap metadata checks come first, and the file is
/// only opened once every one of them has passed.
enum ScreenshotClassifier {

    enum Verdict: Sendable, Equatable {
        case screenshot(CapturedScreenshot)
        /// macOS did not mark it as a screen capture. The overwhelmingly common
        /// answer, and a silent one — most files that land on a Desktop are put
        /// there by the user.
        case notAScreenshot
        /// The bytes are not all there yet. Worth another look shortly.
        case unfinished
        case tooLarge(bytes: Int)
        case unsupportedFormat
        case unreadable(String)
    }

    /// The largest screenshot that will be copied.
    ///
    /// A 6K Retina capture lands around 10–25 MB, so this clears a
    /// multi-display shot with headroom. It is a bound on what the pasteboard
    /// and the clipboard history are asked to hold, not a judgement about the
    /// picture.
    static let maximumBytes = 32 * 1024 * 1024

    static func classify(
        url: URL,
        maximumBytes: Int = maximumBytes,
        isScreenCapture: (String) -> Bool = { ScreenshotXattr.isScreenCapture(atPath: $0) },
        readData: (URL) throws -> Data = { try Data(contentsOf: $0, options: [.mappedIfSafe]) },
        fileSize: (URL) -> Int? = Self.byteCount
    ) -> Verdict {
        guard isImageExtension(url.pathExtension) else { return .unsupportedFormat }
        // Ask macOS before opening anything. A file the user saved themselves
        // must never be read, let alone copied.
        guard isScreenCapture(url.path) else { return .notAScreenshot }
        // Check the size before reading, so an enormous file is never resident.
        if let bytes = fileSize(url), bytes > maximumBytes { return .tooLarge(bytes: bytes) }

        let raw: Data
        do {
            raw = try readData(url)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard raw.count <= maximumBytes else { return .tooLarge(bytes: raw.count) }
        guard !raw.isEmpty else { return .unfinished }
        // Grew while we were reading it: `screencapture` is still writing.
        if let after = fileSize(url), after != raw.count { return .unfinished }
        guard isComplete(raw, pathExtension: url.pathExtension) else { return .unfinished }

        return decode(raw, url: url)
    }

    /// Whether the bytes end where this kind of file is supposed to end.
    ///
    /// ImageIO cannot answer this, which is worth stating because it looks like
    /// it should. `CGImageSourceGetStatus` reports "complete" for a PNG
    /// truncated a third of the way through, whether the source was built from
    /// finished data or updated incrementally, and
    /// `CGImageSourceCreateImageAtIndex` cheerfully decodes that same truncated
    /// PNG into a half-grey picture. Both were measured, not assumed. So the
    /// container's own end marker is the check.
    ///
    /// Formats with no trailer to look for — HEIC, TIFF, BMP — lean on the
    /// size comparison around the read instead. They are rare as screenshot
    /// formats, and a screenshot has to be read twice before it is copied
    /// anyway.
    static func isComplete(_ data: Data, pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "png":
            // The IEND chunk: length 0, type "IEND", and its fixed CRC.
            data.count > 12 && Array(data.suffix(8)) == [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        case "jpg", "jpeg":
            // End of image.
            data.count > 4 && Array(data.suffix(2)) == [0xFF, 0xD9]
        case "gif":
            // Trailer.
            data.count > 6 && data.last == 0x3B
        default:
            true
        }
    }

    /// Reads the size and re-encodes if needed. Completeness was settled
    /// before this ran — see `isComplete` — because nothing ImageIO reports
    /// here would have caught a truncated file.
    private static func decode(_ raw: Data, url: URL) -> Verdict {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return .unfinished
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        guard let png = pngData(from: source, original: raw) else {
            return .unreadable("The screenshot could not be read as an image.")
        }
        return .screenshot(CapturedScreenshot(
            url: url,
            pngData: png,
            pixelWidth: width,
            pixelHeight: height
        ))
    }

    /// `Clip.Kind.image` is documented as PNG-encoded, and a PNG screenshot is
    /// the overwhelming default — so the usual path hands the original bytes
    /// straight through, untouched and un-recompressed. Only a HEIC or JPEG
    /// capture pays for a conversion.
    private static func pngData(from source: CGImageSource, original: Data) -> Data? {
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return original }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Screen *recordings* are `.mov`, and macOS tags them too — so the
    /// extension check is what keeps a video off the pasteboard.
    static func isImageExtension(_ pathExtension: String) -> Bool {
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else { return false }
        guard !type.conforms(to: .movie), !type.conforms(to: .video) else { return false }
        return type.conforms(to: .image)
    }

    private static func byteCount(of url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }
}
