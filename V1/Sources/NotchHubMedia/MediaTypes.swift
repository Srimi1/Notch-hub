import Foundation

public enum MediaTransportCommand: String, CaseIterable, Sendable {
    case previous
    case playPause
    case next
}

public struct MediaNowPlaying: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let appName: String
    public let bundleIdentifier: String?
    public let isPlaying: Bool

    public init(
        title: String,
        artist: String,
        album: String,
        appName: String,
        bundleIdentifier: String?,
        isPlaying: Bool
    ) {
        self.title = MediaTextSanitizer.display(title, maximumLength: 160)
        self.artist = MediaTextSanitizer.display(artist, maximumLength: 120)
        self.album = MediaTextSanitizer.display(album, maximumLength: 160)
        self.appName = MediaTextSanitizer.display(appName, maximumLength: 80)
        self.bundleIdentifier = MediaTextSanitizer.bundleIdentifier(bundleIdentifier)
        self.isPlaying = isPlaying
    }

    public var subtitle: String {
        artist.isEmpty ? appName : artist
    }
}

public enum MediaDiagnosticSeverity: Equatable, Sendable {
    case info
    case warning
    case error
}

public struct MediaDiagnostic: Equatable, Sendable {
    public let severity: MediaDiagnosticSeverity
    public let code: String
    public let summary: String

    public init(severity: MediaDiagnosticSeverity, code: String, summary: String) {
        self.severity = severity
        self.code = code
        self.summary = summary
    }
}

enum MediaSourceIdentity: Sendable {
    case none
    case appleScript
    case adapter
}

enum MediaTextSanitizer {
    static func display(_ value: String, maximumLength: Int) -> String {
        guard maximumLength > 0 else { return "" }
        let outputLimit = min(maximumLength, 4_096)
        let scanLimit = outputLimit * 4
        var singleLine: [UnicodeScalar] = []
        singleLine.reserveCapacity(outputLimit)
        var scanned = 0
        for scalar in value.unicodeScalars {
            guard scanned < scanLimit, singleLine.count < outputLimit else { break }
            scanned += 1
            guard !isBidirectionalControl(scalar) else { continue }
            let sanitized: UnicodeScalar
            if scalar == "\t" || CharacterSet.newlines.contains(scalar) {
                sanitized = " "
            } else {
                sanitized = CharacterSet.controlCharacters.contains(scalar) ? "�" : scalar
            }
            if singleLine.isEmpty, CharacterSet.whitespacesAndNewlines.contains(sanitized) {
                continue
            }
            singleLine.append(sanitized)
        }
        let normalized = String(String.UnicodeScalarView(singleLine))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(outputLimit))
    }

    static func bundleIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var count = 0
        for scalar in value.unicodeScalars {
            count += 1
            guard count <= 255, isBundleIdentifierScalar(scalar) else {
                return nil
            }
        }
        return value
    }

    private static func isBundleIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2D, 0x2E:
            true
        default:
            false
        }
    }

    private static func isBidirectionalControl(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E ... 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
            true
        default:
            false
        }
    }
}

struct MediaApplication: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?

    private static let knownNames: [String: String] = [
        "com.apple.Music": "Music",
        "com.apple.iTunes": "Music",
        "com.apple.podcasts": "Podcasts",
        "com.apple.TV": "TV",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.spotify.client": "Spotify",
        "com.github.th-ch.youtube-music": "YouTube Music",
        "app.ytmdesktop.ytmdesktop": "YouTube Music",
        "com.tidal.desktop": "TIDAL",
        "com.deezer.deezer-desktop": "Deezer",
        "org.videolan.vlc": "VLC",
        "com.colliderli.iina": "IINA",
        "tv.plex.plexamp": "Plexamp",
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome Canary",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    static func resolve(
        bundleIdentifier: String?,
        parentBundleIdentifier: String? = nil,
        localizedName: (String) -> String?
    ) -> MediaApplication {
        let bundleIdentifier = MediaTextSanitizer.bundleIdentifier(bundleIdentifier)
        let parent = MediaTextSanitizer.bundleIdentifier(parentBundleIdentifier)
        guard let bundleIdentifier else {
            return MediaApplication(
                name: resolvedName(for: parent, localizedName: localizedName) ?? "Unknown",
                bundleIdentifier: parent
            )
        }
        let name = resolvedName(for: bundleIdentifier, localizedName: localizedName)
            ?? resolvedName(for: parent, localizedName: localizedName)
            ?? fallbackName(for: bundleIdentifier)
        return MediaApplication(name: name, bundleIdentifier: bundleIdentifier)
    }

    private static func resolvedName(
        for bundleIdentifier: String?,
        localizedName: (String) -> String?
    ) -> String? {
        guard let bundleIdentifier else { return nil }
        if let known = knownNames[bundleIdentifier] { return known }
        guard let name = localizedName(bundleIdentifier) else { return nil }
        let sanitized = MediaTextSanitizer.display(name, maximumLength: 80)
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func fallbackName(for bundleIdentifier: String) -> String {
        let tail = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        return tail.isEmpty ? "Unknown" : String(tail.prefix(80))
    }
}
