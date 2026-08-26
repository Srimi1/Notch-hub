import Foundation
import Testing
@testable import NotchHub

/// The astronaut is decoration, so the rule is that a missing or broken file
/// costs nothing. These pin that, and that the file actually shipped.
@Suite("Astronaut animation")
struct AstronautAnimationTests {

    /// The vendored artwork, found from this file rather than from a bundle —
    /// under `swift test` there is no `.app` to look inside.
    private static var vendored: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Animations/astronaut-and-music.json")
    }

    /// The rule `AdapterLocator` established and this follows: a file that is
    /// not there answers nil, so the view draws nothing and the panel reads
    /// exactly as it did before. Decoration is never worth an error.
    @Test
    func aMissingAnimationResolvesToNothing() {
        let found = AnimationLocator.locate(
            AnimationLocator.astronautName,
            bundle: .main,
            environment: [:],
            fileExists: { _ in false }
        )

        #expect(found == nil)
    }

    /// `swift run` has no app bundle, so the override is what makes the
    /// animation resolvable outside a packaged build.
    @Test
    func theEnvironmentOverrideIsSearchedFirst() {
        let found = AnimationLocator.locate(
            AnimationLocator.astronautName,
            bundle: .main,
            environment: [AnimationLocator.directoryEnvironmentKey: "/fixtures/animations"],
            fileExists: { $0 == "/fixtures/animations/astronaut-and-music.json" }
        )

        #expect(found?.path == "/fixtures/animations/astronaut-and-music.json")
    }

    /// An empty override must not shadow the bundle — an unset environment
    /// variable reads as an empty string in some launch contexts.
    @Test
    func anEmptyOverrideIsIgnored() {
        let found = AnimationLocator.locate(
            AnimationLocator.astronautName,
            bundle: .main,
            environment: [AnimationLocator.directoryEnvironmentKey: ""],
            fileExists: { $0.hasSuffix("Animations/astronaut-and-music.json") }
        )

        #expect(found?.path.hasSuffix("Animations/astronaut-and-music.json") == true)
    }

    /// The artwork is in the repository and is a Lottie file Lottie can read.
    /// Without this, a bad vendoring would only show up as an empty space in
    /// the notch on someone else's machine.
    @Test
    func theVendoredArtworkIsPresentAndDecodes() throws {
        #expect(FileManager.default.fileExists(atPath: Self.vendored.path))

        let duration = try #require(AstronautAnimation.duration(of: Self.vendored))

        // 300 frames at 60fps — the loop as the designer authored it.
        #expect(abs(duration - 5) < 0.05)
    }

    /// Bytes that are not a Lottie file have to come back as nil rather than
    /// throwing out of the view's loading task.
    @Test
    func somethingThatIsNotAnAnimationDecodesToNothing() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchHubTests.\(UUID().uuidString).json")
        try Data("{\"not\": \"a lottie\"}".utf8).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(AstronautAnimation.duration(of: scratch) == nil)
    }
}

/// The astronaut is listening along, so it moves while the music does. Holding
/// still is also what Reduce Motion asks for, and the two reasons collapse into
/// one rule.
@Suite("Astronaut playback")
struct AstronautPlaybackTests {

    @Test
    func movesWhileTheMusicPlays() {
        #expect(AstronautMotion(isPlaying: true, reduceMotion: false) == .looping)
    }

    @Test
    func settlesWhenTheMusicIsPaused() {
        #expect(AstronautMotion(isPlaying: false, reduceMotion: false) == .still)
    }

    /// Reduce Motion wins over playback: a track playing does not license
    /// motion the reader has asked the system not to show them.
    @Test
    func holdsStillUnderReduceMotionEvenWhilePlaying() {
        #expect(AstronautMotion(isPlaying: true, reduceMotion: true) == .still)
        #expect(AstronautMotion(isPlaying: false, reduceMotion: true) == .still)
    }
}

/// The artwork is drawn for a light ground and goes on the black pill, where
/// its near-black measures 1.12:1 against the background. Inverting it is what
/// makes it visible there, and it has to invert without disturbing anything
/// else in the file.
@Suite("Astronaut ink")
struct AstronautInkTests {

    /// The two tones swap: the figure turns white so it reads on black, and the
    /// helmet highlight turns black so it stays a cutout rather than becoming
    /// the figure.
    @Test
    func swapsTheTwoTonesAndLeavesTheRestAlone() throws {
        let source = """
        {"v":"5.6.3","w":1000,"h":1000,"layers":[
          {"nm":"figure","shapes":[{"ty":"fl","c":{"a":0,"k":[0.098,0.047,0.137,1]}}]},
          {"nm":"highlight","shapes":[{"ty":"fl","c":{"a":0,"k":[1,1,1,1]}}]},
          {"nm":"midtone","shapes":[{"ty":"fl","c":{"a":0,"k":[0.5,0.5,0.5,1]}}]}
        ]}
        """
        let out = try AstronautAnimation.inverted(Data(source.utf8))
        let root = try #require(
            try JSONSerialization.jsonObject(with: out) as? [String: Any]
        )
        let layers = try #require(root["layers"] as? [[String: Any]])

        func fill(_ layer: [String: Any]) throws -> [Double] {
            let shapes = try #require(layer["shapes"] as? [[String: Any]])
            let colour = try #require(shapes[0]["c"] as? [String: Any])
            let channels = try #require(colour["k"] as? [Double])
            return Array(channels.prefix(3))
        }

        #expect(try fill(layers[0]) == [1, 1, 1], "the figure should read on black")
        #expect(try fill(layers[1]) == [0, 0, 0], "the highlight should stay a cutout")
        // Anything that is neither tone is left as it was, so a future revision
        // of the artwork degrades to "partly inverted" rather than to nonsense.
        #expect(try fill(layers[2]) == [0.5, 0.5, 0.5])
    }

    /// Inverting must not disturb the composition: same canvas, same timeline,
    /// same layers, or Lottie is being handed a different animation.
    @Test
    func leavesTheCompositionIntact() throws {
        // Found from this file rather than from a bundle, the way the suite
        // above already reaches the vendored artwork under `swift test`.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Animations/astronaut-and-music.json")
        let original = try Data(contentsOf: url)
        let inverted = try AstronautAnimation.inverted(original)

        struct Composition: Equatable {
            var layers: Int
            var width: Int
            var lastFrame: Int
        }
        func shape(_ data: Data) throws -> Composition {
            let root = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            return Composition(
                layers: (root["layers"] as? [Any])?.count ?? -1,
                width: root["w"] as? Int ?? -1,
                lastFrame: root["op"] as? Int ?? -1
            )
        }

        #expect(try shape(original) == shape(inverted))
    }

    /// Something that is not JSON at all should throw rather than crash: the
    /// caller already treats a failed decode as "draw the fallback".
    @Test
    func refusesSomethingThatIsNotAnAnimation() {
        #expect(throws: (any Error).self) {
            try AstronautAnimation.inverted(Data("not json".utf8))
        }
    }
}
