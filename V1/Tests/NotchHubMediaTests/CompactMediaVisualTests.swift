import Foundation
import NotchHubSafeFeatures
import Testing
@testable import NotchHubMedia

@Suite("Compact v0.6 media geometry")
@MainActor
struct CompactMediaGeometryTests {
    @Test("The V1 media bar retains the v0.6 dimensions")
    func preservesLegacyDimensions() {
        #expect(CompactNotchTheme.contentHeight == 68)
        #expect(CompactNotchTheme.expandedWidth == 860)
        #expect(CompactNotchTheme.expandedHeight == 136)
        #expect(MediaAstronautView.panelSide == 56)
        #expect(MediaAstronautView.wingSide == 22)
        #expect(MediaAstronautView.figureFraction == 0.46)
    }
}

@Suite("Astronaut animation")
struct AstronautAnimationTests {
    private static var vendoredAnimation: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Animations/astronaut-and-music.json")
    }

    @Test("The vendored v0.6 artwork is present and decodes")
    func decodesVendoredArtwork() throws {
        #expect(FileManager.default.isReadableFile(atPath: Self.vendoredAnimation.path))
        let duration = try #require(AstronautAnimation.duration(of: Self.vendoredAnimation))
        #expect(abs(duration - 5) < 0.05)
    }

    @Test("Playback and Reduce Motion determine astronaut movement")
    func respectsPlaybackAndReduceMotion() {
        #expect(AstronautMotion(isPlaying: true, reduceMotion: false) == .looping)
        #expect(AstronautMotion(isPlaying: false, reduceMotion: false) == .still)
        #expect(AstronautMotion(isPlaying: true, reduceMotion: true) == .still)
    }

    @Test("White ink swaps artwork tones without changing transforms")
    func safelyInvertsArtworkTones() throws {
        let source = """
        {"v":"5.6.3","w":1000,"h":1000,"layers":[
          {"ks":{"s":{"a":0,"k":[100,100,100]}},
           "shapes":[{"ty":"fl","c":{"a":0,"k":[0.098,0.047,0.137,1]}}]},
          {"shapes":[{"ty":"fl","c":{"a":0,"k":[1,1,1,1]}}]}
        ]}
        """
        let output = try AstronautAnimation.inverted(Data(source.utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let layers = try #require(root["layers"] as? [[String: Any]])

        #expect(try colour(in: layers[0]) == [1, 1, 1])
        #expect(try colour(in: layers[1]) == [0, 0, 0])
        let transform = try #require(layers[0]["ks"] as? [String: Any])
        let scale = try #require(transform["s"] as? [String: Any])
        #expect(try #require(scale["k"] as? [Double]) == [100, 100, 100])
    }

    private func colour(in layer: [String: Any]) throws -> [Double] {
        let shapes = try #require(layer["shapes"] as? [[String: Any]])
        let colour = try #require(shapes[0]["c"] as? [String: Any])
        let channels = try #require(colour["k"] as? [Double])
        return Array(channels.prefix(3))
    }
}
