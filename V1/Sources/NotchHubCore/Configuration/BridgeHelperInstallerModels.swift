import Foundation

public struct BridgeHelperCodeIdentity: Equatable, Sendable {
    public let teamIdentifier: String?
    public let signingIdentifier: String?
    public let designatedRequirement: String?
    public let cdHash: Data?

    public init(
        teamIdentifier: String?,
        signingIdentifier: String? = nil,
        designatedRequirement: String? = nil,
        cdHash: Data? = nil
    ) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.designatedRequirement = designatedRequirement
        self.cdHash = cdHash
    }
}

public enum BridgeHelperSignaturePolicy: Equatable, Sendable {
    case release(expectedHostIdentifier: String, expectedHelperIdentifier: String)
    case development
}

public protocol BridgeHelperCodeSignatureValidating: Sendable {
    func validateCode(at url: URL) throws -> BridgeHelperCodeIdentity
}

public struct BridgeHelperStagedCopy: Equatable, Sendable {
    public let url: URL
    public let byteCount: Int
    public let contentDigest: Data

    public init(url: URL, byteCount: Int, contentDigest: Data) {
        self.url = url
        self.byteCount = byteCount
        self.contentDigest = contentDigest
    }
}

public protocol BridgeHelperInstallationFileSystem: Sendable {
    func stageCopy(
        from sourceURL: URL,
        nextTo destinationURL: URL,
        maximumBytes: Int,
        fileMode: UInt16
    ) throws -> BridgeHelperStagedCopy

    func commit(_ stagedCopy: BridgeHelperStagedCopy, to destinationURL: URL) throws
    func discard(_ stagedCopy: BridgeHelperStagedCopy) throws
}

public struct BridgeHelperInstallationResult: Equatable, Sendable {
    public let destinationURL: URL
    public let byteCount: Int
    public let teamIdentifier: String?

    public init(destinationURL: URL, byteCount: Int, teamIdentifier: String?) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
        self.teamIdentifier = teamIdentifier
    }
}

public enum BridgeHelperInstallerError: Error, Equatable, Sendable {
    case invalidPath
    case symbolicLinkRejected
    case unsupportedFileType
    case sourceTooLarge(limit: Int)
    case permissionDenied
    case fileSystemFailure(operation: String, code: Int32)
    case invalidCodeSignature(status: Int32)
    case teamIdentifierMismatch
    case signingIdentifierMismatch
    case releaseIdentityIncomplete
    case stagedIdentityMismatch
    case cleanupFailed
}
