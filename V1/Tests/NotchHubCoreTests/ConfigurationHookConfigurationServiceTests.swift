import Darwin
import Foundation
import Testing
@testable import NotchHubBridge
@testable import NotchHubCore

@Suite("Consent-safe hook configuration application")
struct HookConfigurationServiceTests {
    private let bridgePath = "/fixture/NotchHubHookBridge"

    @Test("Connect and disconnect preserve unrelated user configuration")
    func lifecyclePreservesUnrelatedSettings() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let fileURL = home.appendingPathComponent(".codex/hooks.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let original = Data(
                #"{"theme":"dark","hooks":{"SessionStart":[{"id":"user-hook","command":["/usr/bin/true"]}]}}"#
                    .utf8
            )
            try original.write(to: fileURL)
            let service = HookConfigurationService(homeDirectory: home)

            let connection = try await service.previewConnection(
                provider: .codex,
                bridgeExecutablePath: bridgePath
            )
            #expect(connection.diff.addedOwnedEntryIDs.count == 4)
            let connectionResult = try await service.apply(connection)
            #expect(connectionResult.wroteConfiguration)

            let installed = try Data(contentsOf: fileURL)
            #expect(installed.contains(Data(HookConfigurationPlanner.ownerPrefix.utf8)))
            #expect(try permissions(of: fileURL) == 0o600)

            let disconnection = try await service.previewDisconnection(provider: .codex)
            #expect(disconnection.diff.removedOwnedEntryIDs.count == 4)
            let disconnectionResult = try await service.apply(disconnection)
            #expect(disconnectionResult.wroteConfiguration)

            let finalData = try Data(contentsOf: fileURL)
            let finalRoot = try #require(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
            #expect(finalRoot["theme"] as? String == "dark")
            #expect(!finalData.contains(Data(HookConfigurationPlanner.ownerPrefix.utf8)))
            #expect(containsUserHook(finalRoot))
        }
    }

    @Test("Malformed and oversized configurations fail before consent is issued")
    func malformedAndOversized() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let fileURL = try configurationFile(in: home, provider: .claude)
            try Data("{".utf8).write(to: fileURL)
            let malformedService = HookConfigurationService(homeDirectory: home)

            await #expect(throws: HookConfigurationApplicationError.planning(.malformedJSON)) {
                try await malformedService.previewConnection(
                    provider: .claude,
                    bridgeExecutablePath: bridgePath
                )
            }

            try Data(
                repeating: 0x20,
                count: HookConfigurationPlanner.maximumConfigurationBytes + 1
            ).write(to: fileURL)
            let oversizedService = HookConfigurationService(homeDirectory: home)
            await #expect(
                throws: HookConfigurationApplicationError.configurationTooLarge(
                    limit: HookConfigurationPlanner.maximumConfigurationBytes
                )
            ) {
                try await oversizedService.previewConnection(
                    provider: .claude,
                    bridgeExecutablePath: bridgePath
                )
            }
        }
    }

    @Test("Symlinked configuration files and ancestors are rejected")
    func symlinksRejected() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let targetDirectory = home.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
            let ancestorLink = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: targetDirectory)
            let ancestorService = HookConfigurationService(homeDirectory: home)

            await #expect(throws: HookConfigurationApplicationError.symbolicLinkRejected) {
                try await ancestorService.previewConnection(
                    provider: .codex,
                    bridgeExecutablePath: bridgePath
                )
            }

            try FileManager.default.removeItem(at: ancestorLink)
            try FileManager.default.createDirectory(at: ancestorLink, withIntermediateDirectories: false)
            let targetFile = home.appendingPathComponent("target.json")
            try Data("{}".utf8).write(to: targetFile)
            let fileLink = ancestorLink.appendingPathComponent("hooks.json")
            try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: targetFile)
            let fileService = HookConfigurationService(homeDirectory: home)

            await #expect(throws: HookConfigurationApplicationError.symbolicLinkRejected) {
                try await fileService.previewConnection(
                    provider: .codex,
                    bridgeExecutablePath: bridgePath
                )
            }
        }
    }

    @Test("A concurrent edit invalidates one-time consent without overwriting user data")
    func concurrentModification() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let fileURL = try configurationFile(in: home, provider: .codex)
            try Data("{}".utf8).write(to: fileURL)
            let service = HookConfigurationService(homeDirectory: home)
            let preview = try await service.previewConnection(
                provider: .codex,
                bridgeExecutablePath: bridgePath
            )
            let changed = Data(#"{"theme":"changed"}"#.utf8)
            try changed.write(to: fileURL)

            await #expect(throws: HookConfigurationApplicationError.concurrentModification) {
                try await service.apply(preview)
            }
            #expect(try Data(contentsOf: fileURL) == changed)
            await #expect(throws: HookConfigurationApplicationError.previewUnavailable) {
                try await service.apply(preview)
            }
        }
    }

    @Test("Replacing an inspected parent with a symlink invalidates consent")
    func concurrentAncestorReplacement() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let fileURL = try configurationFile(in: home, provider: .codex)
            try Data("{}".utf8).write(to: fileURL)
            let service = HookConfigurationService(homeDirectory: home)
            let preview = try await service.previewConnection(
                provider: .codex,
                bridgeExecutablePath: bridgePath
            )
            let configurationDirectory = fileURL.deletingLastPathComponent()
            let attackerDirectory = home.appendingPathComponent("attacker", isDirectory: true)
            try FileManager.default.createDirectory(at: attackerDirectory, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: configurationDirectory)
            try FileManager.default.createSymbolicLink(
                at: configurationDirectory,
                withDestinationURL: attackerDirectory
            )

            await #expect(throws: HookConfigurationApplicationError.symbolicLinkRejected) {
                try await service.apply(preview)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: attackerDirectory.path).isEmpty)
        }
    }

    @Test("Unreadable configuration reports a typed permission failure")
    func permissionFailure() async throws {
        try await withConfigurationTemporaryDirectory { home in
            let fileURL = try configurationFile(in: home, provider: .codex)
            try Data("{}".utf8).write(to: fileURL)
            guard Darwin.chmod(fileURL.path, mode_t(0o000)) == 0 else {
                throw ConfigurationTestError.permissions
            }
            let service = HookConfigurationService(homeDirectory: home)
            let result: HookConfigurationApplicationError?
            do {
                _ = try await service.previewConnection(
                    provider: .codex,
                    bridgeExecutablePath: bridgePath
                )
                result = nil
            } catch let error as HookConfigurationApplicationError {
                result = error
            }
            guard Darwin.chmod(fileURL.path, mode_t(0o600)) == 0 else {
                throw ConfigurationTestError.permissions
            }
            #expect(result == .permissionDenied)
        }
    }

    private func configurationFile(
        in home: URL,
        provider: HookConfigurationProvider
    ) throws -> URL {
        let fileURL = home.appendingPathComponent(provider.relativeConfigurationPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return fileURL
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.posixPermissions] as? NSNumber)
        return number.intValue & 0o777
    }

    private func containsUserHook(_ root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else {
                return false
            }
            return entries.contains { ($0["id"] as? String) == "user-hook" }
        }
    }
}

private enum ConfigurationTestError: Error {
    case permissions
}

private func withConfigurationTemporaryDirectory<T: Sendable>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath()
        .appendingPathComponent("NotchHubConfigurationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
        let result = try await operation(directory)
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        let operationError = error
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw error
        }
        throw operationError
    }
}
