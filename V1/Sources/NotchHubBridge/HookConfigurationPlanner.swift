import Foundation

public struct HookConfigurationPlanner: Sendable {
    public static let ownerPrefix = "com.notchhub.v1"
    public static let maximumConfigurationBytes = 1_048_576

    static let codexEvents = ["SessionStart", "PermissionRequest", "Stop", "SessionEnd"]
    static let claudeEvents = ["SessionStart", "PermissionRequest", "Stop", "SessionEnd"]

    private struct MutationResult {
        let ownedEntryIDs: [String]
        let compatibility: HookConfigurationCompatibility
    }

    public init() {}

    public func planConnection(
        provider: HookConfigurationProvider,
        input: HookConfigurationInput,
        bridgeExecutablePath: String
    ) throws -> HookConfigurationPlan {
        let destinationPath = try validatedDestination(provider: provider, input: input)
        try validateBridgePath(bridgeExecutablePath)
        var root = try parseRoot(input: input)

        let mutation = try connectionMutation(
            provider: provider,
            root: &root,
            bridgePath: bridgeExecutablePath
        )

        let proposedData = try serialized(root)
        let existingCanonicalData = try canonicalExistingData(input: input)
        let changed = proposedData != existingCanonicalData
        let change: HookConfigurationChange = if !changed {
            .unchanged
        } else if input.fileKind == .missing {
            .create
        } else {
            .update
        }

        let diff = HookConfigurationDiff(
            provider: provider,
            operation: .connect,
            destinationPath: destinationPath,
            change: change,
            addedOwnedEntryIDs: mutation.ownedEntryIDs,
            removedOwnedEntryIDs: [],
            preservesUnrelatedSettings: true,
            compatibility: mutation.compatibility
        )
        return HookConfigurationPlan(
            diff: diff,
            atomicWrite: changed ? atomicWrite(destinationPath: destinationPath, data: proposedData) : nil
        )
    }

    public func planDisconnection(
        provider: HookConfigurationProvider,
        input: HookConfigurationInput
    ) throws -> HookConfigurationPlan {
        let destinationPath = try validatedDestination(provider: provider, input: input)
        guard input.fileKind != .missing else {
            return unchangedRemoval(provider: provider, destinationPath: destinationPath)
        }

        var root = try parseRoot(input: input)
        let mutation = try disconnectionMutation(provider: provider, root: &root)

        guard !mutation.ownedEntryIDs.isEmpty else {
            return unchangedRemoval(
                provider: provider,
                destinationPath: destinationPath,
                compatibility: mutation.compatibility
            )
        }

        let proposedData = try serialized(root)
        let diff = HookConfigurationDiff(
            provider: provider,
            operation: .disconnect,
            destinationPath: destinationPath,
            change: .removeOwnedEntries,
            addedOwnedEntryIDs: [],
            removedOwnedEntryIDs: mutation.ownedEntryIDs.sorted(),
            preservesUnrelatedSettings: true,
            compatibility: mutation.compatibility
        )
        return HookConfigurationPlan(
            diff: diff,
            atomicWrite: atomicWrite(destinationPath: destinationPath, data: proposedData)
        )
    }

    private func connectionMutation(
        provider: HookConfigurationProvider,
        root: inout [String: Any],
        bridgePath: String
    ) throws -> MutationResult {
        switch provider {
        case .codex:
            let identifiers = try installCodexEntries(root: &root, bridgePath: bridgePath)
            return MutationResult(ownedEntryIDs: identifiers, compatibility: .fullyConfigured)
        case .claude:
            var identifiers = try installClaudeEntries(root: &root, bridgePath: bridgePath)
            let statusLine = try installClaudeStatusLine(root: &root, bridgePath: bridgePath)
            if let identifier = statusLine.ownedEntryID {
                identifiers.append(identifier)
            }
            return MutationResult(ownedEntryIDs: identifiers.sorted(), compatibility: statusLine.compatibility)
        }
    }

    private func disconnectionMutation(
        provider: HookConfigurationProvider,
        root: inout [String: Any]
    ) throws -> MutationResult {
        switch provider {
        case .codex:
            let identifiers = try removeCodexEntries(root: &root)
            return MutationResult(ownedEntryIDs: identifiers, compatibility: .fullyConfigured)
        case .claude:
            var identifiers = try removeClaudeEntries(root: &root)
            let statusLine = try removeClaudeStatusLine(root: &root)
            if let identifier = statusLine.ownedEntryID {
                identifiers.append(identifier)
            }
            return MutationResult(ownedEntryIDs: identifiers.sorted(), compatibility: statusLine.compatibility)
        }
    }

    private func validatedDestination(
        provider: HookConfigurationProvider,
        input: HookConfigurationInput
    ) throws -> String {
        guard input.homeDirectoryPath.hasPrefix("/") else {
            throw HookConfigurationError.homeDirectoryMustBeAbsolute
        }
        guard input.fileKind != .symbolicLink, !input.ancestorContainsSymbolicLink else {
            throw HookConfigurationError.symbolicLinkRejected
        }
        guard input.fileKind == .missing || input.fileKind == .regularFile else {
            throw HookConfigurationError.unsupportedFileType
        }
        guard (input.fileKind == .missing) == (input.existingData == nil) else {
            throw HookConfigurationError.inconsistentFileState
        }

        return URL(fileURLWithPath: input.homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(provider.relativeConfigurationPath)
            .standardizedFileURL.path
    }

    private func validateBridgePath(_ bridgePath: String) throws {
        guard bridgePath.hasPrefix("/") else {
            throw HookConfigurationError.bridgePathMustBeAbsolute
        }
        guard !bridgePath.contains("\0"), !bridgePath.contains("\n"), !bridgePath.contains("\r") else {
            throw HookConfigurationError.invalidBridgePath
        }
    }

    private func parseRoot(input: HookConfigurationInput) throws -> [String: Any] {
        guard let data = input.existingData else {
            return [:]
        }
        guard !data.isEmpty else {
            throw HookConfigurationError.malformedJSON
        }
        guard data.count <= Self.maximumConfigurationBytes else {
            throw HookConfigurationError.configurationTooLarge(limit: Self.maximumConfigurationBytes)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw HookConfigurationError.malformedJSON
        }
        guard let root = object as? [String: Any] else {
            throw HookConfigurationError.rootMustBeObject
        }
        return root
    }

    private func canonicalExistingData(input: HookConfigurationInput) throws -> Data? {
        guard input.existingData != nil else {
            return nil
        }
        return try serialized(parseRoot(input: input))
    }

    private func serialized(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw HookConfigurationError.serializationFailed
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            return data
        } catch {
            throw HookConfigurationError.serializationFailed
        }
    }

    private func atomicWrite(destinationPath: String, data: Data) -> HookAtomicWritePreparation {
        HookAtomicWritePreparation(
            destinationPath: destinationPath,
            temporarySiblingPath: destinationPath + ".notchhub-v1.pending",
            data: data,
            fileMode: 0o600
        )
    }

    private func unchangedRemoval(
        provider: HookConfigurationProvider,
        destinationPath: String,
        compatibility: HookConfigurationCompatibility = .fullyConfigured
    ) -> HookConfigurationPlan {
        let diff = HookConfigurationDiff(
            provider: provider,
            operation: .disconnect,
            destinationPath: destinationPath,
            change: .unchanged,
            addedOwnedEntryIDs: [],
            removedOwnedEntryIDs: [],
            preservesUnrelatedSettings: true,
            compatibility: compatibility
        )
        return HookConfigurationPlan(diff: diff, atomicWrite: nil)
    }
}
