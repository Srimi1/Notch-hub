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

    /// Raised when the inverted file is not the shape the test reads it as.
    enum CompositionError: Error { case notAnObject }

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

    /// A transform is not a colour, however much it looks like one.
    ///
    /// Scale, position and anchor are held in the same `{"k": [...]}` shape a
    /// fill uses, and their numbers fall in the same ranges a tone test asks
    /// about: `[100, 100, 100]` is three numbers above 0.8, and `[0, 0, 0]` is
    /// three below 0.2. Swapping them scaled the artwork to a tenth of a
    /// percent, which drew the astronaut into the notch at a size nobody could
    /// see. Only what sits under a `c` may change.
    @Test
    func leavesTransformsAlone() throws {
        let source = """
        {"v":"5.6.3","w":1000,"h":1000,"layers":[
          {"nm":"figure","ks":{"s":{"a":0,"k":[100,100,100]},"a":{"a":0,"k":[0,0,0]},
           "p":{"a":0,"k":[-14.854,-217.005,0]}},
           "shapes":[{"ty":"fl","c":{"a":0,"k":[0.098,0.047,0.137,1]}}]}
        ]}
        """
        let out = try AstronautAnimation.inverted(Data(source.utf8))
        let object = try JSONSerialization.jsonObject(with: out)
        guard let root = object as? [String: Any],
              let layer = (root["layers"] as? [[String: Any]])?.first,
              let transform = layer["ks"] as? [String: Any]
        else { throw CompositionError.notAnObject }

        func value(_ name: String) throws -> [Double] {
            guard let property = transform[name] as? [String: Any],
                  let numbers = property["k"] as? [Double]
            else { throw CompositionError.notAnObject }
            return numbers
        }

        #expect(try value("s") == [100, 100, 100], "scale is not a colour")
        #expect(try value("a") == [0, 0, 0], "an anchor at the origin is not black")
        #expect(try value("p") == [-14.854, -217.005, 0], "position is not a colour")

        // The fill it sits beside still inverts, or the test proves nothing.
        let shapes = try #require(layer["shapes"] as? [[String: Any]])
        let colour = try #require(shapes[0]["c"] as? [String: Any])
        let channels = try #require(colour["k"] as? [Double])
        #expect(Array(channels.prefix(3)) == [1, 1, 1])
    }

    /// An animated fill keeps its channels under each keyframe rather than
    /// directly under `k`, and has to invert the same way a static one does.
    @Test
    func swapsAnimatedFillsToo() throws {
        let source = """
        {"v":"5.6.3","w":1000,"h":1000,"layers":[
          {"nm":"pulse","shapes":[{"ty":"fl","c":{"a":1,"k":[
            {"t":0,"s":[0.098,0.047,0.137,1],"e":[1,1,1,1]}
          ]}}]}
        ]}
        """
        let out = try AstronautAnimation.inverted(Data(source.utf8))
        let object = try JSONSerialization.jsonObject(with: out)
        guard let root = object as? [String: Any],
              let layer = (root["layers"] as? [[String: Any]])?.first,
              let shapes = layer["shapes"] as? [[String: Any]],
              let colour = shapes[0]["c"] as? [String: Any],
              let frames = colour["k"] as? [[String: Any]],
              let start = frames[0]["s"] as? [Double],
              let end = frames[0]["e"] as? [Double]
        else { throw CompositionError.notAnObject }

        #expect(Array(start.prefix(3)) == [1, 1, 1])
        #expect(Array(end.prefix(3)) == [0, 0, 0])
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
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw CompositionError.notAnObject
            }
            return Composition(
                layers: (root["layers"] as? [Any])?.count ?? -1,
                width: root["w"] as? Int ?? -1,
                lastFrame: root["op"] as? Int ?? -1
            )
        }

        #expect(try shape(original) == shape(inverted))

        // Every number outside a colour has to come back identical. The real
        // artwork holds forty of them that read as a tone if you ask the
        // question of the wrong node — eleven of those are a scale of
        // `[100, 100, 100]`, and swapping one is the difference between an
        // astronaut and a tenth of a percent of an astronaut.
        #expect(try transforms(of: original) == transforms(of: inverted))
    }

    /// Every `k` that is not inside a `c`, flattened, in document order.
    private func transforms(of data: Data) throws -> [Double] {
        var found: [Double] = []
        func walk(_ node: Any, insideColour: Bool) {
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
                    if key == "k", !insideColour, let numbers = value as? [Double] {
                        found.append(contentsOf: numbers)
                    }
                    walk(value, insideColour: insideColour || key == "c")
                }
            } else if let array = node as? [Any] {
                for element in array { walk(element, insideColour: insideColour) }
            }
        }
        walk(try JSONSerialization.jsonObject(with: data), insideColour: false)
        return found
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
