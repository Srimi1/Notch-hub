import Foundation
import Testing
@testable import NotchHubMedia

@Suite("Media adapter JSON parsing")
struct AdapterParsingTests {
    @Test("A full upstream payload becomes a sanitized media snapshot")
    func parsesFullPayload() {
        let parsed = MediaRemoteAdapterSource.parse(line: envelope("""
        {
          "bundleIdentifier": "com.google.Chrome.app.opaque",
          "parentApplicationBundleIdentifier": "com.google.Chrome",
          "playing": true,
          "title": " Nightcall\\n ",
          "artist": "Kavinsky",
          "album": "OutRun"
        }
        """))

        #expect(parsed == .media(MediaRemoteAdapterSource.StreamPayload(
            title: "Nightcall",
            artist: "Kavinsky",
            album: "OutRun",
            bundleIdentifier: "com.google.Chrome.app.opaque",
            parentBundleIdentifier: "com.google.Chrome",
            isPlaying: true
        )))
    }

    @Test("An empty or titleless payload truthfully means no active track")
    func parsesNothingPlaying() {
        #expect(MediaRemoteAdapterSource.parse(line: envelope("{}")) == .nothingPlaying)
        #expect(
            MediaRemoteAdapterSource.parse(
                line: envelope(#"{"bundleIdentifier":"com.spotify.client","playing":true}"#)
            ) == .nothingPlaying
        )
        #expect(
            MediaRemoteAdapterSource.parse(line: envelope(#"{"title":"   ","playing":true}"#))
                == .nothingPlaying
        )
    }

    @Test("Paused playback remains controllable media with safe defaults")
    func parsesPausedPayload() {
        let parsed = MediaRemoteAdapterSource.parse(
            line: envelope(#"{"title":"Teardrop","playing":false}"#)
        )
        guard case let .media(payload) = parsed else {
            Issue.record("Expected a media payload, got \(parsed)")
            return
        }

        #expect(!payload.isPlaying)
        #expect(payload.artist.isEmpty)
        #expect(payload.album.isEmpty)
        #expect(payload.bundleIdentifier == nil)
    }

    @Test("Non-data envelopes and missing payloads are ignored without clearing state")
    func ignoresUnrelatedMessages() {
        #expect(MediaRemoteAdapterSource.parse(line: "") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: "   ") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: #"{"type":"error","payload":{}}"#) == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: #"{"type":"data"}"#) == .ignored)
    }

    @Test("Malformed, mistyped, and oversized input is rejected")
    func rejectsUntrustedInput() {
        let oversized = String(repeating: "x", count: LineAccumulator.maximumBufferedBytes + 1)

        #expect(MediaRemoteAdapterSource.parse(line: "not json") == .malformed)
        #expect(MediaRemoteAdapterSource.parse(line: "[1,2,3]") == .malformed)
        #expect(MediaRemoteAdapterSource.parse(line: #"{"type":"data","payload":7}"#) == .malformed)
        #expect(MediaRemoteAdapterSource.parse(line: oversized) == .malformed)
    }

    private func envelope(_ payload: String) -> String {
        #"{"type":"data","diff":false,"payload":\#(payload)}"#
    }
}
