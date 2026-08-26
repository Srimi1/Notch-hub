import Foundation
import Testing
@testable import NotchHub

/// The fake launcher proves the source's logic; this proves the real one. It
/// runs `/usr/bin/perl` — the same interpreter the adapter uses — over a
/// throwaway script, so process spawning, chunked line assembly, exit reporting
/// and termination are exercised for real rather than mocked.
@Suite("Adapter process launcher")
struct AdapterProcessLauncherTests {

    private func makeLauncher(body: String) throws -> (AdapterProcessLauncher, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchhub-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-adapter.pl")
        try body.write(to: script, atomically: true, encoding: .utf8)
        // The second argument is the framework path, which the real script takes
        // and this one ignores; passing the directory keeps the shape honest.
        let paths = AdapterLocator.Paths(
            perl: AdapterLocator.perlPath,
            script: script.path,
            framework: directory.path
        )
        return (AdapterProcessLauncher(paths: paths), directory)
    }

    @Test
    func linesArriveWholeAndTheExitStatusIsReported() async throws {
        let (launcher, directory) = try makeLauncher(body: """
        $| = 1;
        print "{\\"type\\":\\"data\\",\\"diff\\":false,\\"payload\\":{}}\\n";
        print "second line\\n";
        exit 3;
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try launcher.launch(arguments: [])
        var events: [AdapterEvent] = []
        for await event in session.events { events.append(event) }

        #expect(events == [
            .line("{\"type\":\"data\",\"diff\":false,\"payload\":{}}"),
            .line("second line"),
            .exited(status: 3)
        ])
        // And the first line is one the parser understands, end to end.
        #expect(MediaRemoteAdapterSource.parse(line: "{\"type\":\"data\",\"diff\":false,\"payload\":{}}")
            == .nothingPlaying)
    }

    /// Nothing reaps a child when the app exits, so terminating has to actually
    /// work — otherwise every launch leaves a stray adapter behind.
    @Test
    func terminatingStopsALongRunningStream() async throws {
        let (launcher, directory) = try makeLauncher(body: """
        $| = 1;
        print "started\\n";
        sleep 120;
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try launcher.launch(arguments: [])
        var sawStart = false
        var exited = false
        for await event in session.events {
            switch event {
            case .line("started"):
                sawStart = true
                session.handle.terminate()
            case .exited:
                exited = true
            default:
                break
            }
        }

        #expect(sawStart)
        #expect(exited)
        #expect(session.handle.isRunning == false)
    }

    /// A process that bursts far more than a pipe buffer and exits in the same
    /// breath is the shape that used to interleave: two readers took the same
    /// descriptor at once, so chunks could land in the accumulator out of order
    /// — garbled JSON, dropped updates. A distinct fill per line makes any
    /// interleaving fail the uniformity check, and the loop amplifies a
    /// probabilistic race into a reliable failure.
    @Test
    func aBurstOfLongLinesArrivesIntactAndInOrder() async throws {
        let (launcher, directory) = try makeLauncher(body: """
        $| = 1;
        for my $i (1..8) { print chr(ord("0") + $i) x 65536, "\\n"; }
        exit 0;
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        for _ in 0 ..< 5 {
            let session = try launcher.launch(arguments: [])
            var events: [AdapterEvent] = []
            for await event in session.events { events.append(event) }

            #expect(events.count == 9)
            #expect(events.last == .exited(status: 0))
            for (index, event) in events.dropLast().enumerated() {
                guard case let .line(line) = event else {
                    Issue.record("event \(index) was not a line")
                    continue
                }
                let fill = Character("\(index + 1)")
                #expect(line.count == 65536)
                #expect(line.allSatisfy { $0 == fill })
            }
        }
    }

    /// A bundle path is full of regex metacharacters, and `pkill -f` takes a
    /// regex. An unescaped dot in `NotchHub.app` would match any character.
    @Test
    func theStrayPatternEscapesTheBundlePath() {
        let pattern = AdapterProcessLauncher.strayPattern(
            scriptPath: "/Applications/NotchHub.app/Contents/Resources/mediaremote-adapter.pl"
        )
        #expect(pattern == "/Applications/NotchHub\\.app/Contents/Resources/mediaremote-adapter\\.pl")
    }

    /// Force-quitting the app orphans the stream, so the next launch has to
    /// clear it — and has to clear only its own.
    @Test
    func reapingKillsAStrayFromAnEarlierRunAndNothingElse() async throws {
        let (launcher, directory) = try makeLauncher(body: """
        $| = 1;
        print "started\\n";
        sleep 120;
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stand in for the orphan: same script path, not owned by this session.
        let stray = try launcher.launch(arguments: [])
        var bystander: AdapterProcessHandle?
        let (other, otherDirectory) = try makeLauncher(body: "$| = 1; print \"other\\n\"; sleep 120;")
        defer {
            bystander?.terminate()
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        bystander = try other.launch(arguments: []).handle

        try await Task.sleep(nanoseconds: 300_000_000)
        launcher.reapStrays()
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(stray.handle.isRunning == false)
        #expect(bystander?.isRunning == true)
    }

    @Test
    func amissingExecutableThrowsRatherThanHanging() throws {
        let paths = AdapterLocator.Paths(
            perl: "/nonexistent/perl",
            script: "/nonexistent/script.pl",
            framework: "/nonexistent"
        )
        #expect(throws: (any Error).self) {
            _ = try AdapterProcessLauncher(paths: paths).launch(arguments: [])
        }
    }
}
