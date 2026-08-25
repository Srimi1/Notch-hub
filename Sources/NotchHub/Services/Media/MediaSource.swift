import AppKit
import Foundation

/// What is playing, wherever it is playing.
///
/// Deliberately player-agnostic: the same shape comes back whether the track
/// was read over Apple Events from Spotify or off the system's own now-playing
/// state, so the UI never has to care which one answered.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var app: MediaApp
    var isPlaying: Bool
}

/// The app a track is coming from.
///
/// `name` is what the user sees. It is not derived from the bundle identifier
/// by string surgery — a bundle id like `com.google.Chrome.app.pbjkfaieekjhcgjb`
/// is a YouTube Music web app, and only macOS knows that. Ask macOS first, fall
/// back to a table for the players that matter, and only then to something
/// synthesised.
struct MediaApp: Equatable {
    var name: String
    var bundleId: String?

    /// Names we insist on, either because the app has no sensible localized
    /// name or because macOS reports one the user would not recognise.
    static let knownNames: [String: String] = [
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
        "com.operasoftware.Opera": "Opera"
    ]

    /// Resolve a display name for a bundle identifier.
    ///
    /// - Parameters:
    ///   - bundleId: the app reporting the track. May be a web-app or helper id.
    ///   - parentBundleId: the app hosting it, when the reporter is a web app.
    ///   - localizedName: how macOS names a bundle id, injected for testability.
    static func resolve(
        bundleId: String?,
        parentBundleId: String? = nil,
        localizedName: (String) -> String? = MediaApp.runningApplicationName
    ) -> MediaApp {
        guard let bundleId, !bundleId.isEmpty else {
            let parentName = parentBundleId.flatMap { knownNames[$0] ?? localizedName($0) }
            return MediaApp(name: parentName ?? "Unknown", bundleId: parentBundleId)
        }
        if let known = knownNames[bundleId] {
            return MediaApp(name: known, bundleId: bundleId)
        }
        // A running web app knows its own name ("YouTube Music"), which is the
        // whole reason a browser tab can be labelled properly at all.
        if let localized = localizedName(bundleId), !localized.isEmpty {
            return MediaApp(name: localized, bundleId: bundleId)
        }
        if let parentBundleId {
            if let known = knownNames[parentBundleId] {
                return MediaApp(name: known, bundleId: bundleId)
            }
            if let localized = localizedName(parentBundleId), !localized.isEmpty {
                return MediaApp(name: localized, bundleId: bundleId)
            }
        }
        return MediaApp(name: fallbackName(for: bundleId), bundleId: bundleId)
    }

    /// Last resort: the most specific-looking piece of the identifier, title-cased.
    /// `com.example.NightOwl` becomes `NightOwl`, not `com.example.NightOwl`.
    static func fallbackName(for bundleId: String) -> String {
        let tail = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        return tail.isEmpty ? bundleId : tail
    }

    static func runningApplicationName(for bundleId: String) -> String? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .compactMap(\.localizedName)
            .first
    }
}

/// One way of learning what is playing and steering it.
///
/// Two implementations exist and they fail differently, which is the point:
/// Apple Events can be denied by the user but reads Spotify and Music exactly,
/// while the MediaRemote adapter needs no permission and sees every player but
/// depends on a private framework Apple can break.
@MainActor
protocol MediaSource: AnyObject {
    var nowPlaying: NowPlaying? { get }
    /// Called whenever `nowPlaying` changes.
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()

    func playPause()
    func next()
    func previous()
}
