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
