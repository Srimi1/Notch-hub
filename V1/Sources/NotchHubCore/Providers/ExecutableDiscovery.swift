import Foundation

public enum ExecutableSource: String, CaseIterable, Codable, Hashable, Sendable {
    case path
    case homebrew
    case local
    case nvm
    case volta
    case bun
    case mise
    case asdf
}

public struct DiscoveredExecutable: Codable, Hashable, Sendable {
    public let provider: ProviderID
    public let url: URL
    public let source: ExecutableSource

    public init(provider: ProviderID, url: URL, source: ExecutableSource) {
        self.provider = provider
        self.url = url
        self.source = source
    }
}

public enum ExecutableDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case unreadableSearchLocation(ExecutableSource)

    public var errorDescription: String? {
        switch self {
        case let .unreadableSearchLocation(source):
            "The \(source.rawValue) executable search location could not be read."
        }
    }
}

public struct ExecutableDiscoveryEnvironment: Hashable, Sendable {
    public let homeDirectory: URL
    public let pathEntries: [URL]

    public init(homeDirectory: URL, pathEntries: [URL]) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.pathEntries = Array(pathEntries.prefix(ExecutableDiscovery.maximumPathEntries))
            .filter { $0.isFileURL && $0.path.hasPrefix("/") }
            .map(\.standardizedFileURL)
    }

    public static func current() -> ExecutableDiscoveryEnvironment {
        let pathEntries = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { entry -> URL? in
                guard entry.hasPrefix("/") else {
                    return nil
                }
                return URL(fileURLWithPath: String(entry), isDirectory: true)
            }
        return ExecutableDiscoveryEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            pathEntries: pathEntries
        )
    }
}

public protocol ExecutableDiscoveryFileSystem: Sendable {
    func isDirectory(_ url: URL) -> Bool
    func isExecutableFile(_ url: URL) -> Bool
    func directoryContents(_ url: URL) throws -> [URL]
}

public struct SystemExecutableDiscoveryFileSystem: ExecutableDiscoveryFileSystem {
    public init() {}

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isExecutableFile(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func directoryContents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}

public struct ExecutableDiscovery: Sendable {
    public static let maximumPathEntries = 64
    public static let maximumVersionDirectories = 32
    public static let maximumCandidates = 160

    private let fileSystem: any ExecutableDiscoveryFileSystem

    public init(fileSystem: any ExecutableDiscoveryFileSystem = SystemExecutableDiscoveryFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func discover(
        _ provider: ProviderID,
        environment: ExecutableDiscoveryEnvironment = .current()
    ) throws -> DiscoveredExecutable? {
        let candidates = try candidates(for: provider, environment: environment)
        return candidates.first(where: { fileSystem.isExecutableFile($0.url) })
    }

    public func candidates(
        for provider: ProviderID,
        environment: ExecutableDiscoveryEnvironment = .current()
    ) throws -> [DiscoveredExecutable] {
        var candidates: [DiscoveredExecutable] = []
        appendPathCandidates(provider, environment: environment, to: &candidates)
        appendStaticCandidates(provider, environment: environment, to: &candidates)
        try appendVersionedCandidates(provider, environment: environment, to: &candidates)
        return deduplicated(Array(candidates.prefix(Self.maximumCandidates)))
    }

    private func appendPathCandidates(
        _ provider: ProviderID,
        environment: ExecutableDiscoveryEnvironment,
        to candidates: inout [DiscoveredExecutable]
    ) {
        for directory in environment.pathEntries {
            append(provider, directory: directory, source: .path, to: &candidates)
        }
    }

    private func appendStaticCandidates(
        _ provider: ProviderID,
        environment: ExecutableDiscoveryEnvironment,
        to candidates: inout [DiscoveredExecutable]
    ) {
        let home = environment.homeDirectory
        let locations: [(URL, ExecutableSource)] = [
            (URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true), .homebrew),
            (URL(fileURLWithPath: "/usr/local/bin", isDirectory: true), .homebrew),
            (home.appending(path: ".local/bin", directoryHint: .isDirectory), .local),
            (home.appending(path: ".volta/bin", directoryHint: .isDirectory), .volta),
            (home.appending(path: ".bun/bin", directoryHint: .isDirectory), .bun),
            (home.appending(path: ".local/share/mise/shims", directoryHint: .isDirectory), .mise),
            (home.appending(path: ".asdf/shims", directoryHint: .isDirectory), .asdf),
        ]
        for (directory, source) in locations {
            append(provider, directory: directory, source: source, to: &candidates)
        }
    }

    private func appendVersionedCandidates(
        _ provider: ProviderID,
        environment: ExecutableDiscoveryEnvironment,
        to candidates: inout [DiscoveredExecutable]
    ) throws {
        let home = environment.homeDirectory
        let locations: [(URL, ExecutableSource)] = [
            (home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory), .nvm),
            (home.appending(path: ".local/share/mise/installs/node", directoryHint: .isDirectory), .mise),
            (home.appending(path: ".asdf/installs/nodejs", directoryHint: .isDirectory), .asdf),
        ]

        for (root, source) in locations where fileSystem.isDirectory(root) {
            let versionDirectories: [URL]
            do {
                versionDirectories = try fileSystem.directoryContents(root)
            } catch {
                throw ExecutableDiscoveryError.unreadableSearchLocation(source)
            }
            for directory in boundedVersionDirectories(versionDirectories) {
                append(
                    provider,
                    directory: directory.appending(path: "bin", directoryHint: .isDirectory),
                    source: source,
                    to: &candidates
                )
            }
        }
    }

    private func append(
        _ provider: ProviderID,
        directory: URL,
        source: ExecutableSource,
        to candidates: inout [DiscoveredExecutable]
    ) {
        let url = directory.appending(path: provider.executableName, directoryHint: .notDirectory)
            .standardizedFileURL
        candidates.append(DiscoveredExecutable(provider: provider, url: url, source: source))
    }

    private func boundedVersionDirectories(_ contents: [URL]) -> [URL] {
        contents
            .filter { fileSystem.isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .prefix(Self.maximumVersionDirectories)
            .map(\.standardizedFileURL)
    }

    private func deduplicated(_ candidates: [DiscoveredExecutable]) -> [DiscoveredExecutable] {
        var paths = Set<String>()
        return candidates.filter { paths.insert($0.url.path).inserted }
    }
}
