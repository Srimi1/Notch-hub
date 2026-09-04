import Foundation
import Testing
@testable import NotchHubMedia

@Suite("Media metadata safety")
struct MediaTypesTests {
    @Test("External metadata is single-line, bounded, and safe to present")
    func sanitizesExternalMetadataBeforePresentation() {
        let track = MediaNowPlaying(
            title: "  Song\nTitle\u{0000}\u{202E}\u{2066}  ",
            artist: "Artist\tName",
            album: String(repeating: "a", count: 200),
            appName: String(repeating: "p", count: 100),
            bundleIdentifier: "com.example.player;bad",
            isPlaying: true
        )

        #expect(track.title == "Song Title�")
        #expect(track.artist == "Artist Name")
        #expect(track.album.count == 160)
        #expect(track.appName.count == 80)
        #expect(track.bundleIdentifier == nil)
        #expect(track.isPlaying)
    }

    @Test("Every Unicode newline is flattened")
    func flattensUnicodeNewlines() {
        let separators = ["\n", "\u{000B}", "\u{000C}", "\r", "\u{0085}", "\u{2028}", "\u{2029}"]

        for separator in separators {
            #expect(MediaTextSanitizer.display("before\(separator)after", maximumLength: 80) == "before after")
        }
    }

    @Test("Very large external metadata is bounded before presentation")
    func boundsVeryLargeInput() {
        let untrusted = String(repeating: "x", count: 1_000_000)

        #expect(MediaTextSanitizer.display(untrusted, maximumLength: 160).count == 160)
        #expect(MediaTextSanitizer.bundleIdentifier(untrusted) == nil)
    }

    @Test("Bundle identifiers retain only their bounded canonical character set")
    func sanitizesBundleIdentifiers() {
        let longIdentifier = String(repeating: "a", count: 300) + "/../../bad"

        #expect(MediaTextSanitizer.bundleIdentifier(nil) == nil)
        #expect(MediaTextSanitizer.bundleIdentifier("!!!") == nil)
        #expect(MediaTextSanitizer.bundleIdentifier("com.example-player.beta") == "com.example-player.beta")
        #expect(MediaTextSanitizer.bundleIdentifier("com.example_player") == nil)
        #expect(MediaTextSanitizer.bundleIdentifier("com.spötify.client") == nil)
        #expect(MediaTextSanitizer.bundleIdentifier(longIdentifier) == nil)
    }

    @Test("Artist is preferred for the compact subtitle with app fallback")
    func subtitleUsesHonestFallback() {
        let artistTrack = track(artist: "Kavinsky", appName: "Music")
        let appTrack = track(artist: "", appName: "Spotify")

        #expect(artistTrack.subtitle == "Kavinsky")
        #expect(appTrack.subtitle == "Spotify")
    }

    private func track(artist: String, appName: String) -> MediaNowPlaying {
        MediaNowPlaying(
            title: "Nightcall",
            artist: artist,
            album: "OutRun",
            appName: appName,
            bundleIdentifier: "com.example.player",
            isPlaying: true
        )
    }
}

@Suite("Media application naming")
struct MediaApplicationTests {
    private func noLocalizedName(_: String) -> String? { nil }

    @Test("Known players and browsers retain their user-facing names")
    func resolvesKnownApplications() {
        #expect(
            MediaApplication.resolve(
                bundleIdentifier: "com.spotify.client",
                localizedName: noLocalizedName
            ).name == "Spotify"
        )
        #expect(
            MediaApplication.resolve(
                bundleIdentifier: "com.github.th-ch.youtube-music",
                localizedName: noLocalizedName
            ).name == "YouTube Music"
        )
    }

    @Test("A browser-hosted player falls back to its parent application")
    func resolvesParentApplication() {
        let application = MediaApplication.resolve(
            bundleIdentifier: "com.google.Chrome.helper.media",
            parentBundleIdentifier: "com.google.Chrome",
            localizedName: noLocalizedName
        )

        #expect(application.name == "Chrome")
        #expect(application.bundleIdentifier == "com.google.Chrome.helper.media")
    }

    @Test("System names win and unknown identifiers still produce honest labels")
    func resolvesDynamicAndFallbackNames() {
        let webApplication = MediaApplication.resolve(
            bundleIdentifier: "com.google.Chrome.app.opaque",
            parentBundleIdentifier: "com.google.Chrome",
            localizedName: { $0.hasSuffix("opaque") ? "YouTube Music" : nil }
        )
        let unknown = MediaApplication.resolve(
            bundleIdentifier: "com.example.NightOwl",
            localizedName: noLocalizedName
        )
        let absent = MediaApplication.resolve(
            bundleIdentifier: nil,
            localizedName: noLocalizedName
        )

        #expect(webApplication.name == "YouTube Music")
        #expect(unknown.name == "NightOwl")
        #expect(absent.name == "Unknown")
    }
}
