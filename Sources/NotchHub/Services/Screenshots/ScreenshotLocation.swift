import Foundation

/// The image formats `screencapture` can be told to write.
///
/// Only the ones that carry a bitmap can be put on the pasteboard as a picture.
/// `pdf` is a real setting people use, so it is named rather than lumped into
/// `other` — the difference is what lets Settings explain why nothing is being
/// copied instead of leaving the feature looking broken.
enum ScreenshotFormat: Equatable, Sendable {
    case png
    case jpg
    case tiff
    case heic
    case gif
    case bmp
    case pdf
    case other(String)

    static func named(_ raw: String?) -> ScreenshotFormat {
        switch raw?.lowercased() {
        case nil, "": .png
        case "png": .png
        case "jpg", "jpeg": .jpg
        case "tiff": .tiff
        case "heic": .heic
        case "gif": .gif
        case "bmp": .bmp
        case "pdf": .pdf
        case .some(let raw): .other(raw)
        }
    }

    var isImage: Bool {
        switch self {
        case .png, .jpg, .tiff, .heic, .gif, .bmp: true
        case .pdf, .other: false
        }
    }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPEG"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .pdf: "PDF"
        case .other(let raw): raw.uppercased()
        }
    }
}

/// Where macOS is currently saving screenshots, and in what format.
///
/// Both come from the `com.apple.screencapture` defaults domain, which anyone
/// can write with a `defaults write` and which macOS never announces a change
/// to. Everything here is a pure function of the two raw strings so the rules
/// can be tested without a Desktop, a Spotlight index, or a real preference.
struct ScreenshotLocation: Equatable, Sendable {
    var folder: URL
    var format: ScreenshotFormat

    static let defaultsSuiteName = "com.apple.screencapture"
    private static let locationKey = "location"
    private static let typeKey = "type"

    /// The name to show in Settings — "Desktop", not the whole path.
    var folderName: String { folder.lastPathComponent }

    static func read(
        defaults: UserDefaults? = UserDefaults(suiteName: defaultsSuiteName),
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> ScreenshotLocation {
        resolve(
            location: defaults?.string(forKey: locationKey),
            type: defaults?.string(forKey: typeKey),
            home: home
        )
    }

    /// Unset means the Desktop — the same thing `screencapture` does, and not
    /// the same thing as an empty path. A raw `~/Shots` reaching `open(2)`
    /// would create a literal `./~` directory rather than resolving, so the
    /// tilde is expanded here, once.
    static func resolve(location: String?, type: String?, home: URL) -> ScreenshotLocation {
        ScreenshotLocation(
            folder: folder(from: location, home: home),
            format: ScreenshotFormat.named(type)
        )
    }

    private static func folder(from location: String?, home: URL) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL

        guard let location else { return desktop }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktop }

        // System Settings has been known to store the location as a file URL.
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }

        let expanded = expandingTilde(trimmed, home: home)
        // A relative path has no meaning to a background app whose working
        // directory is not the user's — treat it the way an unset value is.
        guard expanded.hasPrefix("/") else { return desktop }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private static func expandingTilde(_ path: String, home: URL) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return home.path }
        guard path.hasPrefix("~/") else { return path }
        return home.appendingPathComponent(String(path.dropFirst(2))).path
    }
}
