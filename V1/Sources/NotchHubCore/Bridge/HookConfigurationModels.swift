import Foundation

public enum HookConfigurationProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    public var relativeConfigurationPath: String {
        switch self {
        case .codex:
            ".codex/hooks.json"
        case .claude:
            ".claude/settings.json"
        }
    }
}

public enum HookConfigurationFileKind: String, Codable, CaseIterable, Sendable {
    case missing
    case regularFile
    case symbolicLink
    case other
}

public struct HookConfigurationInput: Equatable, Sendable {
    public let homeDirectoryPath: String
    public let existingData: Data?
    public let fileKind: HookConfigurationFileKind
    public let ancestorContainsSymbolicLink: Bool

    public init(
        homeDirectoryPath: String,
        existingData: Data?,
        fileKind: HookConfigurationFileKind,
        ancestorContainsSymbolicLink: Bool = false
    ) {
        self.homeDirectoryPath = homeDirectoryPath
        self.existingData = existingData
        self.fileKind = fileKind
        self.ancestorContainsSymbolicLink = ancestorContainsSymbolicLink
    }
}

public enum HookConfigurationOperation: String, Codable, CaseIterable, Sendable {
    case connect
    case disconnect
}

public enum HookConfigurationChange: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case removeOwnedEntries
    case unchanged
}

public enum HookConfigurationCompatibility: String, Codable, CaseIterable, Sendable {
    case fullyConfigured
    case customClaudeStatusLinePreserved
}

public struct HookConfigurationDiff: Equatable, Sendable {
    public let provider: HookConfigurationProvider
    public let operation: HookConfigurationOperation
    public let destinationPath: String
    public let change: HookConfigurationChange
    public let addedOwnedEntryIDs: [String]
    public let removedOwnedEntryIDs: [String]
    public let preservesUnrelatedSettings: Bool
    public let compatibility: HookConfigurationCompatibility

    public init(
        provider: HookConfigurationProvider,
        operation: HookConfigurationOperation,
        destinationPath: String,
        change: HookConfigurationChange,
        addedOwnedEntryIDs: [String],
        removedOwnedEntryIDs: [String],
        preservesUnrelatedSettings: Bool,
        compatibility: HookConfigurationCompatibility = .fullyConfigured
    ) {
        self.provider = provider
        self.operation = operation
        self.destinationPath = destinationPath
        self.change = change
        self.addedOwnedEntryIDs = addedOwnedEntryIDs
        self.removedOwnedEntryIDs = removedOwnedEntryIDs
        self.preservesUnrelatedSettings = preservesUnrelatedSettings
        self.compatibility = compatibility
    }
}

public struct HookAtomicWritePreparation: Equatable, Sendable {
    public let destinationPath: String
    public let temporarySiblingPath: String
    public let data: Data
    public let fileMode: UInt16

    public init(destinationPath: String, temporarySiblingPath: String, data: Data, fileMode: UInt16) {
        self.destinationPath = destinationPath
        self.temporarySiblingPath = temporarySiblingPath
        self.data = data
        self.fileMode = fileMode
    }
}

public struct HookConfigurationPlan: Equatable, Sendable {
    public let diff: HookConfigurationDiff
    public let atomicWrite: HookAtomicWritePreparation?

    public init(diff: HookConfigurationDiff, atomicWrite: HookAtomicWritePreparation?) {
        self.diff = diff
        self.atomicWrite = atomicWrite
    }
}

public enum HookConfigurationError: Error, Equatable, Sendable {
    case homeDirectoryMustBeAbsolute
    case symbolicLinkRejected
    case unsupportedFileType
    case inconsistentFileState
    case configurationTooLarge(limit: Int)
    case malformedJSON
    case rootMustBeObject
    case invalidHooksShape(String)
    case bridgePathMustBeAbsolute
    case invalidBridgePath
    case conflictingOwnedEntry(String)
    case serializationFailed
}
