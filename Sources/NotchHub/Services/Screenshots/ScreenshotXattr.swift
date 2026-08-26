import Foundation

/// Reads the metadata `screencapture` stamps onto every file it saves.
///
/// macOS writes `kMDItemIsScreenCapture` (a binary plist holding `true`) as an
/// extended attribute on the file itself, at save time. That is what makes this
/// feature possible without waiting on Spotlight: the tag is on the bytes the
/// moment they land, so a new file can be judged immediately.
///
/// The alternatives were both worse. Filenames are localized and the English
/// form separates the time from AM/PM with U+202F NARROW NO-BREAK SPACE, so
/// pattern-matching them is a bug waiting to happen. `NSMetadataQuery` waits on
/// the Spotlight index, which can be seconds behind — long enough for the copy
/// to land after the user's next ⌘V.
///
/// Nothing here is isolated: it is called from the watch queue, and it holds no
/// state.
enum ScreenshotXattr {

    static let isScreenCaptureName = "com.apple.metadata:kMDItemIsScreenCapture"
    static let captureTypeName = "com.apple.metadata:kMDItemScreenCaptureType"

    /// Whether macOS itself says this file is a screenshot.
    ///
    /// This is the feature's safety property. Everything that reaches the
    /// pasteboard passes through here, so a file the user merely saved to their
    /// Desktop is never touched.
    static func isScreenCapture(
        atPath path: String,
        read: (String, String) -> Data? = data(atPath:name:)
    ) -> Bool {
        guard let raw = read(path, isScreenCaptureName) else { return false }
        return isScreenCapture(raw)
    }

    /// "display", "window", or "selection" — for diagnostics only.
    static func captureType(
        atPath path: String,
        read: (String, String) -> Data? = data(atPath:name:)
    ) -> String? {
        guard let raw = read(path, captureTypeName) else { return nil }
        return decode(raw) as? String
    }

    /// The attribute being *present* is not the same as it being *true*, and a
    /// malformed value is a classification miss rather than a screenshot.
    static func isScreenCapture(_ raw: Data) -> Bool {
        decode(raw) as? Bool == true
    }

    /// A bad plist here means one file is not recognised as a screenshot. It is
    /// worth a line in the log and nothing more — no `lastError`, because there
    /// is nothing the user could do about it and most files reaching this point
    /// are not screenshots anyway.
    private static func decode(_ raw: Data) -> Any? {
        guard !raw.isEmpty else { return nil }
        do {
            return try PropertyListSerialization.propertyList(from: raw, options: [], format: nil)
        } catch {
            NSLog("NotchHub screenshots: unreadable capture metadata: %@", error.localizedDescription)
            return nil
        }
    }

    /// Raw extended-attribute bytes, or nil when the attribute is absent.
    ///
    /// `XATTR_NOFOLLOW` on purpose: a symlink sitting on the Desktop carries no
    /// tag of its own, and following it would let a link to an arbitrary file
    /// inherit a screenshot's classification.
    static func data(atPath path: String, name: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { destination in
            getxattr(path, name, destination.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        // A short read means the attribute changed underneath us; treat the
        // partial value as absent rather than decoding a truncated plist.
        guard read == length else { return nil }
        return Data(buffer)
    }
}
