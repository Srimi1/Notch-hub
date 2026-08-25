import Foundation
import Testing
@testable import NotchHub

/// The adapter hands us newline-delimited JSON from a process we do not
/// control, on a schema upstream warns may shift between minor versions. Every
/// shape it can produce has to land somewhere sane — never a blank row, never a
/// crash, never "nothing is playing" while something is.
@Suite("Media stream parsing")
struct MediaStreamParsingTests {

    private func line(_ payload: String, type: String = "data") -> String {
        "{\"type\":\"\(type)\",\"diff\":false,\"payload\":\(payload)}"
    }

    @Test
    func aFullPayloadBecomesATrack() throws {
        let parsed = MediaRemoteAdapterSource.parse(line: line("""
        {"bundleIdentifier":"com.google.Chrome.app.abc",
         "parentApplicationBundleIdentifier":"com.google.Chrome",
         "playing":true,"title":"Nightcall","artist":"Kavinsky","album":"OutRun"}
        """))

        #expect(parsed == .media(MediaRemoteAdapterSource.StreamPayload(
            title: "Nightcall",
            artist: "Kavinsky",
            album: "OutRun",
            bundleId: "com.google.Chrome.app.abc",
            parentBundleId: "com.google.Chrome",
            isPlaying: true
        )))
    }

    /// Upstream sends an empty payload dictionary when no player is reporting.
    @Test
    func anEmptyPayloadMeansNothingIsPlaying() {
        #expect(MediaRemoteAdapterSource.parse(line: line("{}")) == .nothingPlaying)
    }

    /// "Media without a title is considered invalid" — showing a blank title
    /// row would be worse than showing nothing.
    @Test
    func aTitlelessPayloadIsNotATrack() {
        #expect(MediaRemoteAdapterSource.parse(
            line: line(#"{"bundleIdentifier":"com.spotify.client","playing":true}"#)
        ) == .nothingPlaying)
        #expect(MediaRemoteAdapterSource.parse(
            line: line(#"{"title":"   ","playing":true}"#)
        ) == .nothingPlaying)
    }

    /// A paused track is still a track — the transport row needs it to offer
    /// "play".
    @Test
    func aPausedTrackIsStillReported() {
        let parsed = MediaRemoteAdapterSource.parse(
            line: line(#"{"title":"Teardrop","playing":false,"bundleIdentifier":"com.apple.Music"}"#)
        )
        guard case let .media(payload) = parsed else {
            Issue.record("expected a track, got \(parsed)")
            return
        }
        #expect(payload.isPlaying == false)
        #expect(payload.artist.isEmpty)
        #expect(payload.album.isEmpty)
    }

    /// Anything that is not a data message is noise, and noise must not be
    /// mistaken for "the player stopped".
    @Test
    func nonDataLinesAreIgnored() {
        #expect(MediaRemoteAdapterSource.parse(line: "") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: "   ") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: "not json at all") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: "null") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: "[1,2,3]") == .ignored)
        #expect(MediaRemoteAdapterSource.parse(line: line("{}", type: "error")) == .ignored)
    }

    /// The difference between "the adapter said nothing is playing" and "the
    /// adapter said something we could not read" decides whether the crash
    /// counter resets, so a data line with no payload key must not be treated
    /// as a silence report.
    @Test
    func aDataLineWithoutAPayloadIsIgnored() {
        #expect(MediaRemoteAdapterSource.parse(line: #"{"type":"data","diff":false}"#) == .ignored)
    }
}

/// A bundle identifier is not a name. `com.google.Chrome.app.pbjk…` is what
/// macOS calls the YouTube Music web app, and the user calls "YouTube Music".
@Suite("Media app naming")
struct MediaAppNamingTests {

    private func noNames(_: String) -> String? { nil }

    @Test
    func knownPlayersKeepTheirRealNames() {
        #expect(MediaApp.resolve(bundleId: "com.spotify.client", localizedName: noNames).name == "Spotify")
        #expect(MediaApp.resolve(bundleId: "com.apple.Music", localizedName: noNames).name == "Music")
        #expect(
            MediaApp.resolve(bundleId: "com.github.th-ch.youtube-music", localizedName: noNames).name
                == "YouTube Music"
        )
    }

    /// The whole point of asking macOS: a web app knows it is YouTube Music
    /// even though its bundle id is an opaque Chrome-generated string.
    @Test
    func aWebAppIsNamedByTheSystemNotByItsIdentifier() {
        let app = MediaApp.resolve(
            bundleId: "com.google.Chrome.app.pbjkfaieekjhcgjb",
            parentBundleId: "com.google.Chrome",
            localizedName: { $0 == "com.google.Chrome.app.pbjkfaieekjhcgjb" ? "YouTube Music" : nil }
        )
        #expect(app.name == "YouTube Music")
        #expect(app.bundleId == "com.google.Chrome.app.pbjkfaieekjhcgjb")
    }

    /// A plain browser tab is honestly labelled with the browser. Claiming
    /// otherwise would be inventing information we do not have.
    @Test
    func aTabFallsBackToItsHostApplication() {
        let app = MediaApp.resolve(
            bundleId: "com.google.Chrome.helper.media",
            parentBundleId: "com.google.Chrome",
            localizedName: noNames
        )
        #expect(app.name == "Chrome")
        #expect(app.bundleId == "com.google.Chrome.helper.media")
    }

    @Test
    func anUnknownPlayerIsNamedFromItsIdentifierRatherThanLeftBlank() {
        #expect(MediaApp.resolve(bundleId: "com.example.NightOwl", localizedName: noNames).name == "NightOwl")
        #expect(MediaApp.resolve(bundleId: "singleword", localizedName: noNames).name == "singleword")
    }

    @Test
    func amissingIdentifierStillProducesSomethingToShow() {
        #expect(MediaApp.resolve(bundleId: nil, localizedName: noNames).name == "Unknown")
        #expect(MediaApp.resolve(bundleId: "", localizedName: noNames).name == "Unknown")
        #expect(
            MediaApp.resolve(bundleId: nil, parentBundleId: "com.apple.Safari", localizedName: noNames).name
                == "Safari"
        )
    }
}

/// Chunked reads are the normal case, not the edge case: a JSON object routinely
/// arrives split across two reads, and the half-line has to be kept.
@Suite("Adapter line buffering")
struct LineAccumulatorTests {

    @Test
    func completeLinesComeOutWhole() {
        let accumulator = LineAccumulator()
        #expect(accumulator.append(Data("one\ntwo\n".utf8)) == ["one", "two"])
    }

    @Test
    func aLineSplitAcrossReadsIsReassembled() {
        let accumulator = LineAccumulator()
        #expect(accumulator.append(Data("{\"type\":\"da".utf8)).isEmpty)
        #expect(accumulator.append(Data("ta\"}\n".utf8)) == ["{\"type\":\"data\"}"])
    }

    @Test
    func theTailIsOnlyDeliveredOnFlush() {
        let accumulator = LineAccumulator()
        #expect(accumulator.append(Data("done\nhalf".utf8)) == ["done"])
        #expect(accumulator.flush() == "half")
        #expect(accumulator.flush() == nil)
    }

    /// A producer that never emits a newline must not be able to grow the
    /// buffer until the app is killed.
    @Test
    func anEndlessLineIsDroppedRatherThanBuffered() {
        let accumulator = LineAccumulator()
        let huge = Data(repeating: UInt8(ascii: "x"), count: LineAccumulator.maximumBufferedBytes + 1)
        #expect(accumulator.append(huge).isEmpty)
        #expect(accumulator.flush() == nil)
        // And it recovers: the next complete line still parses.
        #expect(accumulator.append(Data("after\n".utf8)) == ["after"])
    }
}

/// Locating the adapter has to fail softly. A missing file means "run without
/// it", never a crash and never a broken app.
@Suite("Adapter location")
struct AdapterLocatorTests {

    @Test
    func theOverrideDirectoryWinsWhenBothFilesAreThere() {
        let paths = AdapterLocator.locate(
            environment: [AdapterLocator.directoryEnvironmentKey: "/opt/adapter"],
            fileExists: { $0.hasPrefix("/opt/adapter") || $0 == AdapterLocator.perlPath }
        )
        #expect(paths?.script == "/opt/adapter/mediaremote-adapter.pl")
        #expect(paths?.framework == "/opt/adapter/MediaRemoteAdapter.framework")
        #expect(paths?.perl == AdapterLocator.perlPath)
    }

    @Test
    func ahalfInstalledAdapterIsNotUsed() {
        let paths = AdapterLocator.locate(
            environment: [AdapterLocator.directoryEnvironmentKey: "/opt/adapter"],
            fileExists: { $0 == AdapterLocator.perlPath || $0.hasSuffix(".pl") }
        )
        #expect(paths == nil)
    }

    /// No perl, no adapter — the entire approach rests on that one binary.
    @Test
    func withoutPerlThereIsNoAdapter() {
        let paths = AdapterLocator.locate(
            environment: [AdapterLocator.directoryEnvironmentKey: "/opt/adapter"],
            fileExists: { $0 != AdapterLocator.perlPath }
        )
        #expect(paths == nil)
    }

    /// The contract between `scripts/build-app.sh` and this locator: the script
    /// goes in `Contents/Resources`, the framework in `Contents/Frameworks`. If
    /// either side moves, the adapter silently stops being found and NotchHub
    /// quietly falls back to Music-and-Spotify-only.
    @Test
    func theBundleLayoutMatchesWhatTheBuildScriptProduces() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotchHubLocator-\(UUID().uuidString).app")
        let contents = root.appendingPathComponent("Contents")
        let manager = FileManager.default
        try manager.createDirectory(
            at: contents.appendingPathComponent("Resources"),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: contents.appendingPathComponent("Frameworks"),
            withIntermediateDirectories: true
        )
        defer { try? manager.removeItem(at: root) }
        try "<plist/>".write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        let script = contents.appendingPathComponent("Resources/\(AdapterLocator.scriptName)")
        let framework = contents.appendingPathComponent("Frameworks/\(AdapterLocator.frameworkName)")
        try "#!/usr/bin/perl\n".write(to: script, atomically: true, encoding: .utf8)
        try manager.createDirectory(at: framework, withIntermediateDirectories: true)

        let bundle = try #require(Bundle(url: root))
        let paths = AdapterLocator.locate(bundle: bundle, environment: [:])

        #expect(paths?.script == script.path)
        #expect(paths?.framework == framework.path)
    }

    @Test
    func anEmptyOverrideIsIgnoredRatherThanSearchedAsARootPath() {
        let paths = AdapterLocator.locate(
            bundle: Bundle(for: LocatorProbe.self),
            environment: [AdapterLocator.directoryEnvironmentKey: ""],
            fileExists: { $0 == AdapterLocator.perlPath }
        )
        #expect(paths == nil)
    }

    private final class LocatorProbe {}
}
