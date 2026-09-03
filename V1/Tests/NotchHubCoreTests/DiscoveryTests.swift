import Foundation
import Testing
@testable import NotchHubCore

@Suite("Bounded executable discovery")
struct DiscoveryTests {
    @Test("PATH has precedence without invoking a shell")
    func pathPrecedence() throws {
        let environment = fixtureEnvironment(pathEntries: ["/fixture/custom/bin"])
        let expected = URL(fileURLWithPath: "/fixture/custom/bin/codex")
        let discovery = ExecutableDiscovery(
            fileSystem: FixtureDiscoveryFileSystem(executables: [expected.path])
        )

        let result = try discovery.discover(.codex, environment: environment)
        #expect(result?.url == expected)
        #expect(result?.source == .path)
    }

    @Test("Standard managers are included in the bounded candidate set")
    func standardLocations() throws {
        let environment = fixtureEnvironment()
        let fileSystem = FixtureDiscoveryFileSystem(
            directories: [
                "/fixture/home/.nvm/versions/node": ["v22.1.0"],
                "/fixture/home/.local/share/mise/installs/node": ["22.1.0"],
                "/fixture/home/.asdf/installs/nodejs": ["22.1.0"],
            ]
        )
        let candidates = try ExecutableDiscovery(fileSystem: fileSystem)
            .candidates(for: .claude, environment: environment)
        let paths = Set(candidates.map(\.url.path))

        #expect(paths.contains("/opt/homebrew/bin/claude"))
        #expect(paths.contains("/usr/local/bin/claude"))
        #expect(paths.contains("/fixture/home/.local/bin/claude"))
        #expect(paths.contains("/fixture/home/.nvm/versions/node/v22.1.0/bin/claude"))
        #expect(paths.contains("/fixture/home/.volta/bin/claude"))
        #expect(paths.contains("/fixture/home/.bun/bin/claude"))
        #expect(paths.contains("/fixture/home/.local/share/mise/shims/claude"))
        #expect(paths.contains("/fixture/home/.asdf/shims/claude"))
    }

    @Test("A missing CLI returns nil")
    func missingCLI() throws {
        let result = try ExecutableDiscovery(fileSystem: FixtureDiscoveryFileSystem())
            .discover(.codex, environment: fixtureEnvironment())
        #expect(result == nil)
    }

    @Test("PATH and version directory traversal are capped")
    func searchBounds() throws {
        let pathEntries = (0 ..< 100).map { "/fixture/path-\($0)" }
        let versions = (0 ..< 100).map { "v\($0)" }
        let environment = fixtureEnvironment(pathEntries: pathEntries)
        let fileSystem = FixtureDiscoveryFileSystem(
            directories: ["/fixture/home/.nvm/versions/node": versions]
        )
        let candidates = try ExecutableDiscovery(fileSystem: fileSystem)
            .candidates(for: .codex, environment: environment)

        let pathCount = candidates.filter { $0.source == .path }.count
        let nvmCount = candidates.filter { $0.source == .nvm }.count
        #expect(pathCount == ExecutableDiscovery.maximumPathEntries)
        #expect(nvmCount == ExecutableDiscovery.maximumVersionDirectories)
        #expect(candidates.count <= ExecutableDiscovery.maximumCandidates)
    }

    @Test("Unreadable version directories produce a typed, path-free error")
    func unreadableDirectory() {
        let fileSystem = FixtureDiscoveryFileSystem(
            directories: ["/fixture/home/.nvm/versions/node": []],
            unreadableDirectories: ["/fixture/home/.nvm/versions/node"]
        )
        #expect(throws: ExecutableDiscoveryError.unreadableSearchLocation(.nvm)) {
            try ExecutableDiscovery(fileSystem: fileSystem)
                .candidates(for: .codex, environment: fixtureEnvironment())
        }
    }

    private func fixtureEnvironment(
        pathEntries: [String] = []
    ) -> ExecutableDiscoveryEnvironment {
        ExecutableDiscoveryEnvironment(
            homeDirectory: URL(fileURLWithPath: "/fixture/home", isDirectory: true),
            pathEntries: pathEntries.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}

private struct FixtureDiscoveryFileSystem: ExecutableDiscoveryFileSystem {
    private struct FixtureReadError: Error {}

    let executables: Set<String>
    let directories: [String: [String]]
    let unreadableDirectories: Set<String>

    init(
        executables: Set<String> = [],
        directories: [String: [String]] = [:],
        unreadableDirectories: Set<String> = []
    ) {
        self.executables = executables
        self.directories = directories
        self.unreadableDirectories = unreadableDirectories
    }

    func isDirectory(_ url: URL) -> Bool {
        directories[url.path] != nil || directories.values.flatMap(\.self).contains(url.lastPathComponent)
    }

    func isExecutableFile(_ url: URL) -> Bool {
        executables.contains(url.path)
    }

    func directoryContents(_ url: URL) throws -> [URL] {
        if unreadableDirectories.contains(url.path) {
            throw FixtureReadError()
        }
        return directories[url.path, default: []].map {
            url.appending(path: $0, directoryHint: .isDirectory)
        }
    }
}
