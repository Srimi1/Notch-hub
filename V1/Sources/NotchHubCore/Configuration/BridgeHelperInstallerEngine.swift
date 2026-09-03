import Darwin
import Foundation

public actor BridgeHelperInstallerEngine {
    public static let maximumHelperBytes = 33_554_432

    private let fileSystem: any BridgeHelperInstallationFileSystem
    private let signatureValidator: any BridgeHelperCodeSignatureValidating
    private let signaturePolicy: BridgeHelperSignaturePolicy
    private let maximumBytes: Int

    public init(
        fileSystem: any BridgeHelperInstallationFileSystem = LocalBridgeHelperInstallationFileSystem(),
        signatureValidator: any BridgeHelperCodeSignatureValidating = SystemBridgeHelperCodeSignatureValidator(),
        signaturePolicy: BridgeHelperSignaturePolicy = .release(
            expectedHostIdentifier: "com.notchhub.app",
            expectedHelperIdentifier: "com.notchhub.v1.bridge.helper"
        ),
        maximumBytes: Int = BridgeHelperInstallerEngine.maximumHelperBytes
    ) {
        self.fileSystem = fileSystem
        self.signatureValidator = signatureValidator
        self.signaturePolicy = signaturePolicy
        self.maximumBytes = min(max(maximumBytes, 1), Self.maximumHelperBytes)
    }

    public func install(
        sourceURL: URL,
        hostBundleURL: URL,
        destinationURL: URL
    ) throws -> BridgeHelperInstallationResult {
        let hostIdentity = try validatedIdentity(at: hostBundleURL)
        let sourceIdentity = try validatedIdentity(at: sourceURL)
        try validateHost(hostIdentity)
        try validateSource(sourceIdentity, host: hostIdentity)

        let stagedCopy = try stage(sourceURL: sourceURL, destinationURL: destinationURL)
        do {
            let stagedIdentity = try validatedIdentity(at: stagedCopy.url)
            guard stagedIdentity == sourceIdentity else {
                throw BridgeHelperInstallerError.stagedIdentityMismatch
            }
            try fileSystem.commit(stagedCopy, to: destinationURL)
        } catch {
            let installationError = mapped(error, operation: "install")
            do {
                try fileSystem.discard(stagedCopy)
            } catch {
                throw BridgeHelperInstallerError.cleanupFailed
            }
            throw installationError
        }
        return BridgeHelperInstallationResult(
            destinationURL: destinationURL,
            byteCount: stagedCopy.byteCount,
            teamIdentifier: sourceIdentity.teamIdentifier
        )
    }

    private func validatedIdentity(at url: URL) throws -> BridgeHelperCodeIdentity {
        do {
            return try signatureValidator.validateCode(at: url)
        } catch {
            throw mapped(error, operation: "signature")
        }
    }

    private func stage(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> BridgeHelperStagedCopy {
        do {
            return try fileSystem.stageCopy(
                from: sourceURL,
                nextTo: destinationURL,
                maximumBytes: maximumBytes,
                fileMode: 0o700
            )
        } catch {
            throw mapped(error, operation: "stage")
        }
    }

    private func validateHost(_ host: BridgeHelperCodeIdentity) throws {
        guard case let .release(expectedHostIdentifier, _) = signaturePolicy else {
            return
        }
        guard completeReleaseIdentity(host) else {
            throw BridgeHelperInstallerError.releaseIdentityIncomplete
        }
        guard host.signingIdentifier == expectedHostIdentifier else {
            throw BridgeHelperInstallerError.signingIdentifierMismatch
        }
    }

    private func validateSource(
        _ source: BridgeHelperCodeIdentity,
        host: BridgeHelperCodeIdentity
    ) throws {
        switch signaturePolicy {
        case let .release(_, expectedHelperIdentifier):
            guard completeReleaseIdentity(source) else {
                throw BridgeHelperInstallerError.releaseIdentityIncomplete
            }
            guard source.teamIdentifier == host.teamIdentifier else {
                throw BridgeHelperInstallerError.teamIdentifierMismatch
            }
            guard source.signingIdentifier == expectedHelperIdentifier else {
                throw BridgeHelperInstallerError.signingIdentifierMismatch
            }
        case .development:
            if let hostTeam = host.teamIdentifier,
               source.teamIdentifier != hostTeam
            {
                throw BridgeHelperInstallerError.teamIdentifierMismatch
            }
        }
    }

    private func completeReleaseIdentity(_ identity: BridgeHelperCodeIdentity) -> Bool {
        guard let teamIdentifier = identity.teamIdentifier,
              !teamIdentifier.isEmpty,
              let signingIdentifier = identity.signingIdentifier,
              !signingIdentifier.isEmpty,
              let designatedRequirement = identity.designatedRequirement,
              !designatedRequirement.isEmpty,
              let cdHash = identity.cdHash,
              !cdHash.isEmpty
        else {
            return false
        }
        return true
    }

    private func mapped(_ error: any Error, operation: String) -> BridgeHelperInstallerError {
        if let error = error as? BridgeHelperInstallerError {
            return error
        }
        return .fileSystemFailure(operation: operation, code: EIO)
    }
}
