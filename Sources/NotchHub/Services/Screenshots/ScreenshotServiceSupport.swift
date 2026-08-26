import AppKit
import Foundation

/// Whether NotchHub can read the folder screenshots are saved in.
///
/// File scope rather than nested inside `ScreenshotService` so it carries no
/// actor isolation: the permission probe runs off the main actor and hands one
/// of these back across that boundary.
enum ScreenshotAccess: Sendable, Equatable {
    /// The folder has not been opened yet, so macOS has not been asked.
    case unknown
    case allowed
    case denied
    case folderMissing
}

/// What one pass over the screenshot folder found.
///
/// Every field is `Sendable`, so the whole result crosses back from the scan
/// task to the main actor as a value.
struct ScanOutcome: Sendable {
    var captures: [CapturedScreenshot] = []
    /// Files that turned up before they were finished, or before macOS had
    /// tagged them. Worth another look shortly.
    var retry: [URL] = []
    var note: String?
    var failure: String?

    init() {}

    /// One file's verdict, as a finished value — so a scan task can build it
    /// and hand it across to the main actor without the variable itself
    /// crossing.
    init(verdict: ScreenshotClassifier.Verdict, at url: URL) {
        absorb(verdict, at: url)
    }

    mutating func absorb(_ verdict: ScreenshotClassifier.Verdict, at url: URL) {
        switch verdict {
        case .screenshot(let capture):
            captures.append(capture)
        case .unfinished:
            retry.append(url)
        case .notAScreenshot, .unsupportedFormat:
            // The common answer, and a silent one: most files that appear in
            // a folder are put there by the user, and saying so every time
            // would be noise about nothing.
            break
        case .tooLarge(let bytes):
            let megabytes = ScreenshotClassifier.maximumBytes / (1024 * 1024)
            note = "That screenshot was \(bytes / (1024 * 1024)) MB — larger than the "
                + "\(megabytes) MB NotchHub will put on the clipboard."
        case .unreadable(let reason):
            failure = reason
        }
    }
}

/// Holds a `NotificationCenter` observer and unregisters it when released.
///
/// The same trick as `NotificationObserverToken`, generalised over the centre:
/// screenshots need both the default centre and the workspace one, and they
/// have different `removeObserver` receivers.
final class ObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    var value: (any NSObjectProtocol)?

    var isEmpty: Bool { value == nil }

    init(center: NotificationCenter) {
        self.center = center
    }

    deinit {
        if let value { center.removeObserver(value) }
    }
}

extension ScreenshotService {

    /// Whether a screenshot NotchHub just copied should also be *kept* — put in
    /// the clipboard history and announced with the copy popup.
    ///
    /// The copy itself is never in question: that is the feature the user
    /// switched on. Hiding the Clipboard module is them saying "don't keep or
    /// show my clipboard in the notch", so that is the half that switches off.
    nonisolated static func shouldRemember(clipboardModuleVisible: Bool) -> Bool {
        clipboardModuleVisible
    }

    /// One directory listing, reduced to what the scan policy needs.
    @Sendable nonisolated static func contents(of folder: URL) throws -> [ScreenshotScanPolicy.Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return ScreenshotScanPolicy.Entry(url: url, modified: modified, size: values.fileSize ?? 0)
        }
    }

    /// Opens the folder to find out whether macOS will allow it.
    ///
    /// There is no API that answers "may I read this folder" — the only way to
    /// know is to try, which is also what raises the dialog. Blocking, so this
    /// must never be called on the main actor.
    @Sendable nonisolated static func probeAccess(to folder: URL) -> ScreenshotAccess {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [],
                options: [.skipsSubdirectoryDescendants]
            )
            return .allowed
        } catch {
            let failure = error as NSError
            let missing = failure.domain == NSCocoaErrorDomain
                && failure.code == NSFileReadNoSuchFileError
            return missing ? .folderMissing : .denied
        }
    }

    /// Recoverable by design: the classification rests on metadata macOS writes
    /// but does not document, so a mistake here must never be a lost file.
    @Sendable nonisolated static func moveToTrash(_ url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    /// Whether a directory-listing failure is macOS refusing rather than the
    /// folder being broken — the difference between "grant access" and
    /// "something is wrong", which are different sentences to show a user.
    nonisolated static func isPermissionFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("permission")
            || message.localizedCaseInsensitiveContains("don’t have permission")
    }

    /// A format that cannot become a picture on the pasteboard is worth saying
    /// out loud. Silently copying nothing forever reads as a broken feature.
    nonisolated static func formatNote(for format: ScreenshotFormat) -> String? {
        guard !format.isImage else { return nil }
        return "Your screenshots are saved as \(format.displayName). NotchHub copies image "
            + "screenshots — change the format in the Screenshot app to copy them."
    }
}
