import Foundation
import Testing
@testable import NotchHubMedia

@Suite("Adapter process launcher")
struct AdapterProcessLauncherTests {
    @Test("Chunked output is assembled and the exact exit status is reported")
    func readsLinesAndExitStatus() async throws {
        let fixture = try makeFixture(script: """
        $| = 1;
        print "first ";
        print "line\\nsecond line\\n";
        print STDERR "private upstream diagnostic\\n";
        exit 3;
        """)
        defer { removeFixture(fixture.directory) }

        let session = try fixture.launcher.launchStream(arguments: [])
        var events: [AdapterEvent] = []
        for await event in session.events { events.append(event) }

        #expect(events == [
            .line("first line"),
            .line("second line"),
            .exited(status: 3),
        ])
        #expect(!session.handle.isRunning)
    }

    @Test("Oversized process output is discarded and the next line recovers")
    func boundsRealProcessOutput() async throws {
        let fixture = try makeFixture(script: """
        $| = 1;
        print "x" x 70000, "\\nvalid\\n";
        exit 0;
        """)
        defer { removeFixture(fixture.directory) }

        let session = try fixture.launcher.launchStream(arguments: [])
        var events: [AdapterEvent] = []
        for await event in session.events { events.append(event) }

        #expect(events.contains(.discardedOutput))
        #expect(events.contains(.line("valid")))
        #expect(events.last == .exited(status: 0))
    }

    @Test("Terminating an owned long-running stream reaps the child")
    func terminatesOwnedProcess() async throws {
        let fixture = try makeFixture(script: """
        $| = 1;
        print "started\\n";
        sleep 120;
        """)
        defer { removeFixture(fixture.directory) }

        let session = try fixture.launcher.launchStream(arguments: [])
        var sawStart = false
        var sawExit = false
        for await event in session.events {
            switch event {
            case .line("started"):
                sawStart = true
                session.handle.terminate()
            case .exited:
                sawExit = true
            default:
                break
            }
        }

        #expect(sawStart)
        #expect(sawExit)
        #expect(!session.handle.isRunning)
    }

    @Test("A detached command reports its bounded child exit status")
    func reportsCommandStatus() async throws {
        let fixture = try makeFixture(script: "exit 7;")
        defer { removeFixture(fixture.directory) }

        let session = try fixture.launcher.launchCommand(arguments: ["send", "4"])
        var statuses: [Int32] = []
        for await status in session.statuses { statuses.append(status) }

        #expect(statuses == [7])
        #expect(!session.handle.isRunning)
    }

    @Test("A missing executable throws rather than leaving an idle session")
    func rejectsMissingExecutable() {
        let paths = AdapterLocator.Paths(
            perl: "/notchhub-test/missing-perl",
            script: "/notchhub-test/missing-script",
            framework: "/notchhub-test/missing-framework"
        )

        #expect(throws: (any Error).self) {
            _ = try AdapterProcessLauncher(paths: paths).launchStream(arguments: [])
        }
    }

    private func makeFixture(script: String) throws -> ProcessFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchHubV1-media-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("adapter.pl", isDirectory: false)
        let frameworkURL = directory.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworkURL, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let paths = AdapterLocator.Paths(
            perl: AdapterLocator.perlPath,
            script: scriptURL.path,
            framework: frameworkURL.path
        )
        return ProcessFixture(
            launcher: AdapterProcessLauncher(paths: paths),
            directory: directory
        )
    }

    private func removeFixture(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove process fixture: \(error.localizedDescription)")
        }
    }
}

private struct ProcessFixture {
    let launcher: AdapterProcessLauncher
    let directory: URL
}
