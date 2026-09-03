import Foundation
import NotchHubBridge

public struct HookConfigurationFileSnapshot: Equatable, Sendable {
    public let input: HookConfigurationInput
    public let identity: Data

    public init(input: HookConfigurationInput, identity: Data) {
        self.input = input
        self.identity = identity
    }
}

public protocol HookConfigurationFileSystem: Sendable {
    func inspect(
        provider: HookConfigurationProvider,
        homeDirectory: URL,
        maximumBytes: Int
    ) throws -> HookConfigurationFileSnapshot

    func replaceAtomically(
        _ data: Data,
        provider: HookConfigurationProvider,
        homeDirectory: URL,
        expected: HookConfigurationFileSnapshot,
        fileMode: UInt16
    ) throws
}

public struct HookConfigurationConsentPreview: Equatable, Sendable {
    public let id: UUID
    public let diff: HookConfigurationDiff
}

public struct HookConfigurationApplicationResult: Equatable, Sendable {
    public let diff: HookConfigurationDiff
    public let wroteConfiguration: Bool

    public init(diff: HookConfigurationDiff, wroteConfiguration: Bool) {
        self.diff = diff
        self.wroteConfiguration = wroteConfiguration
    }
}

public enum HookConfigurationApplicationError: Error, Equatable, Sendable {
    case invalidHomeDirectory
    case symbolicLinkRejected
    case unsupportedFileType
    case configurationTooLarge(limit: Int)
    case permissionDenied
    case fileSystemFailure(operation: String, code: Int32)
    case planning(HookConfigurationError)
    case previewUnavailable
    case previewMismatch
    case concurrentModification
    case invalidAtomicWrite
}
