import Darwin
import Foundation
import Testing
@testable import NotchHubCore

@Suite("Signed bridge helper installer")
struct BridgeInstallerEngineTests {
    @Test("A validated helper is installed atomically with executable-only owner permissions")
    func successfulInstallation() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("EmbeddedBridge")
            let host = directory.appendingPathComponent("NotchHub.app", isDirectory: true)
            let destination = directory
                .appendingPathComponent("Application Support/NotchHub/V1/Bridge", isDirectory: true)
                .appendingPathComponent("NotchHubHookBridge")
            let providerConfiguration = directory.appendingPathComponent(".codex/hooks.json")
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: providerConfiguration.deletingLastPathComponent(),
                withIntermediateDirectories: false
            )
            let helperData = Data("signed-helper-fixture".utf8)
            let providerData = Data(#"{"ownedBy":"user"}"#.utf8)
            try helperData.write(to: source)
            try providerData.write(to: providerConfiguration)
            let engine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { _ in
                    BridgeHelperCodeIdentity(teamIdentifier: "TEAM123")
                },
                signaturePolicy: .development
            )

            let result = try await engine.install(
                sourceURL: source,
                hostBundleURL: host,
                destinationURL: destination
            )

            #expect(result.byteCount == helperData.count)
            #expect(result.teamIdentifier == "TEAM123")
            #expect(try Data(contentsOf: destination) == helperData)
            #expect(try bridgePermissions(of: destination) == 0o700)
            #expect(try Data(contentsOf: providerConfiguration) == providerData)
            let siblings = try FileManager.default.contentsOfDirectory(
                at: destination.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            #expect(siblings.map(\.lastPathComponent) == ["NotchHubHookBridge"])
        }
    }

    @Test("Oversized and symbolic-link sources fail before destination replacement")
    func invalidSources() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let host = directory.appendingPathComponent("NotchHub.app", isDirectory: true)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("Bridge/NotchHubHookBridge")
            let validator = BridgeInstallerSignatureFixture { _ in
                BridgeHelperCodeIdentity(teamIdentifier: nil)
            }
            let engine = BridgeHelperInstallerEngine(
                signatureValidator: validator,
                signaturePolicy: .development,
                maximumBytes: 16
            )
            let oversized = directory.appendingPathComponent("oversized")
            try Data(repeating: 1, count: 17).write(to: oversized)

            await #expect(throws: BridgeHelperInstallerError.sourceTooLarge(limit: 16)) {
                try await engine.install(
                    sourceURL: oversized,
                    hostBundleURL: host,
                    destinationURL: destination
                )
            }

            let target = directory.appendingPathComponent("target")
            let link = directory.appendingPathComponent("link")
            try Data("helper".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            await #expect(throws: BridgeHelperInstallerError.symbolicLinkRejected) {
                try await engine.install(
                    sourceURL: link,
                    hostBundleURL: host,
                    destinationURL: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("Host and helper Team IDs must match before any file is staged")
    func teamMismatch() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("EmbeddedBridge")
            let host = directory.appendingPathComponent("NotchHub.app", isDirectory: true)
            let destination = directory.appendingPathComponent("Bridge/NotchHubHookBridge")
            try Data("helper".utf8).write(to: source)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
            let hostPath = host.path
            let engine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { url in
                    BridgeHelperCodeIdentity(teamIdentifier: url.path == hostPath ? "HOST" : "HELPER")
                },
                signaturePolicy: .development
            )

            await #expect(throws: BridgeHelperInstallerError.teamIdentifierMismatch) {
                try await engine.install(
                    sourceURL: source,
                    hostBundleURL: host,
                    destinationURL: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("A staged signature mismatch is cleaned up without replacing the destination")
    func stagedSignatureMismatch() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("EmbeddedBridge")
            let host = directory.appendingPathComponent("NotchHub.app", isDirectory: true)
            let destination = directory.appendingPathComponent("Bridge/NotchHubHookBridge")
            try Data("helper".utf8).write(to: source)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
            let engine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { url in
                    let isStaged = url.lastPathComponent.hasPrefix(".notchhub-bridge-")
                    return BridgeHelperCodeIdentity(teamIdentifier: isStaged ? "CHANGED" : "TEAM")
                },
                signaturePolicy: .development
            )

            await #expect(throws: BridgeHelperInstallerError.stagedIdentityMismatch) {
                try await engine.install(
                    sourceURL: source,
                    hostBundleURL: host,
                    destinationURL: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let siblings = try FileManager.default.contentsOfDirectory(
                at: destination.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            #expect(siblings.isEmpty)
        }
    }

    @Test("Release policy requires complete exact identities while development permits ad-hoc identities")
    func releaseAndDevelopmentPolicies() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("EmbeddedBridge")
            let host = directory.appendingPathComponent("NotchHub.app", isDirectory: true)
            let destination = directory.appendingPathComponent("Bridge/NotchHubHookBridge")
            try Data("helper".utf8).write(to: source)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
            let hostPath = host.path
            let hostIdentity = BridgeHelperCodeIdentity(
                teamIdentifier: "TEAM",
                signingIdentifier: "com.notchhub.preview",
                designatedRequirement: "host requirement",
                cdHash: Data(repeating: 1, count: 20)
            )
            let helperIdentity = BridgeHelperCodeIdentity(
                teamIdentifier: "TEAM",
                signingIdentifier: "com.notchhub.v1.bridge.helper",
                designatedRequirement: "helper requirement",
                cdHash: Data(repeating: 2, count: 20)
            )
            let releaseEngine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { url in
                    url.path == hostPath ? hostIdentity : helperIdentity
                },
                signaturePolicy: .release(
                    expectedHostIdentifier: "com.notchhub.preview",
                    expectedHelperIdentifier: "com.notchhub.v1.bridge.helper"
                )
            )

            _ = try await releaseEngine.install(
                sourceURL: source,
                hostBundleURL: host,
                destinationURL: destination
            )

            let incompleteEngine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { _ in
                    BridgeHelperCodeIdentity(teamIdentifier: nil)
                },
                signaturePolicy: .release(
                    expectedHostIdentifier: "com.notchhub.preview",
                    expectedHelperIdentifier: "com.notchhub.v1.bridge.helper"
                )
            )
            await #expect(throws: BridgeHelperInstallerError.releaseIdentityIncomplete) {
                try await incompleteEngine.install(
                    sourceURL: source,
                    hostBundleURL: host,
                    destinationURL: destination
                )
            }

            let developmentEngine = BridgeHelperInstallerEngine(
                signatureValidator: BridgeInstallerSignatureFixture { _ in
                    BridgeHelperCodeIdentity(teamIdentifier: nil)
                },
                signaturePolicy: .development
            )
            _ = try await developmentEngine.install(
                sourceURL: source,
                hostBundleURL: host,
                destinationURL: destination
            )
        }
    }

    @Test("Tampering with a staged helper is detected before rename")
    func stagedTampering() async throws {
        try await withBridgeInstallerTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("EmbeddedBridge")
            let destination = directory.appendingPathComponent("Bridge/NotchHubHookBridge")
            try Data("original-helper".utf8).write(to: source)
            let fileSystem = LocalBridgeHelperInstallationFileSystem()
            let staged = try fileSystem.stageCopy(
                from: source,
                nextTo: destination,
                maximumBytes: 1_024,
                fileMode: 0o700
            )
            try Data("tampered-helper".utf8).write(to: staged.url)
            guard chmod(staged.url.path, mode_t(0o700)) == 0 else {
                throw BridgeInstallerTestError.permissions
            }

            #expect(throws: BridgeHelperInstallerError.self) {
                try fileSystem.commit(staged, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            try fileSystem.discard(staged)
        }
    }
}

private struct BridgeInstallerSignatureFixture: BridgeHelperCodeSignatureValidating {
    let resolver: @Sendable (URL) throws -> BridgeHelperCodeIdentity

    init(resolver: @escaping @Sendable (URL) throws -> BridgeHelperCodeIdentity) {
        self.resolver = resolver
    }

    func validateCode(at url: URL) throws -> BridgeHelperCodeIdentity {
        try resolver(url)
    }
}

private enum BridgeInstallerTestError: Error {
    case permissions
}

private func bridgePermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try #require(attributes[.posixPermissions] as? NSNumber)
    return number.intValue & 0o777
}

private func withBridgeInstallerTemporaryDirectory<T: Sendable>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/") ? "/private\(temporaryPath)" : temporaryPath
    let directory = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
        .appendingPathComponent("NotchHubBridgeInstallerTests-\(UUID().uuidString)", isDirectory: true)
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
