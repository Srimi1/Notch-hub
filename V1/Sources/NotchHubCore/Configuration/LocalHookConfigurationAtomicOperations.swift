import Darwin
import Foundation
import NotchHubBridge

extension LocalHookConfigurationFileSystem {
    func replaceInHomeDirectory(
        _ request: ReplacementRequest,
        homeDescriptor: Int32,
        homeIdentity: [String]
    ) throws {
        let directoryStatus = try statusAt(
            directoryDescriptor: homeDescriptor,
            name: request.location.configurationDirectoryName
        )
        if let directoryStatus {
            try replaceInExistingDirectory(
                request,
                homeDescriptor: homeDescriptor,
                homeIdentity: homeIdentity,
                directoryStatus: directoryStatus
            )
            return
        }
        try replaceInNewDirectory(
            request,
            homeDescriptor: homeDescriptor,
            homeIdentity: homeIdentity
        )
    }

    func replaceInExistingDirectory(
        _ request: ReplacementRequest,
        homeDescriptor: Int32,
        homeIdentity: [String],
        directoryStatus: stat
    ) throws {
        try validateOwnedDirectory(directoryStatus)
        try withChildDirectory(
            parentDescriptor: homeDescriptor,
            name: request.location.configurationDirectoryName
        ) { configurationDescriptor in
            let identityParts = homeIdentity + [directoryIdentity(directoryStatus)]
            let current = try inspectFile(
                location: request.location,
                directoryDescriptor: configurationDescriptor,
                identityParts: identityParts,
                maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
            )
            guard current == request.expected else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            try writeAtomically(
                request.data,
                target: atomicWriteTarget(
                    request,
                    descriptor: configurationDescriptor,
                    identityParts: identityParts,
                    expected: current
                )
            )
        }
    }

    func replaceInNewDirectory(
        _ request: ReplacementRequest,
        homeDescriptor: Int32,
        homeIdentity: [String]
    ) throws {
        let missing = missingSnapshot(
            location: request.location,
            identityParts: homeIdentity + ["parent-missing"]
        )
        guard missing == request.expected else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        let createdStatus = try createConfigurationDirectory(request.location, homeDescriptor: homeDescriptor)
        try withChildDirectory(
            parentDescriptor: homeDescriptor,
            name: request.location.configurationDirectoryName
        ) { configurationDescriptor in
            let identityParts = homeIdentity + [directoryIdentity(createdStatus)]
            let current = try inspectFile(
                location: request.location,
                directoryDescriptor: configurationDescriptor,
                identityParts: identityParts,
                maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
            )
            guard current.input.fileKind == .missing else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            try writeAtomically(
                request.data,
                target: atomicWriteTarget(
                    request,
                    descriptor: configurationDescriptor,
                    identityParts: identityParts,
                    expected: current
                )
            )
        }
    }

    func createConfigurationDirectory(
        _ location: ConfigurationLocation,
        homeDescriptor: Int32
    ) throws -> stat {
        guard mkdirat(homeDescriptor, location.configurationDirectoryName, mode_t(0o700)) == 0 else {
            if errno == EEXIST {
                throw HookConfigurationApplicationError.concurrentModification
            }
            throw mappedErrno(operation: "mkdir")
        }
        guard let status = try statusAt(
            directoryDescriptor: homeDescriptor,
            name: location.configurationDirectoryName
        ) else {
            throw HookConfigurationApplicationError.fileSystemFailure(operation: "mkdir-verify", code: ENOENT)
        }
        try validateOwnedDirectory(status)
        return status
    }

    func atomicWriteTarget(
        _ request: ReplacementRequest,
        descriptor: Int32,
        identityParts: [String],
        expected: HookConfigurationFileSnapshot
    ) -> AtomicWriteTarget {
        AtomicWriteTarget(
            location: request.location,
            directoryDescriptor: descriptor,
            identityParts: identityParts,
            expected: expected,
            fileMode: request.fileMode
        )
    }

    func readVerifiedConfiguration(
        _ descriptor: Int32,
        listedStatus: stat,
        maximumBytes: Int
    ) throws -> Data {
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0 else {
            throw mappedErrno(operation: "stat-configuration")
        }
        try validateRegularFile(initialStatus)
        guard fileIdentity(initialStatus) == fileIdentity(listedStatus) else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        guard initialStatus.st_size <= Int64(maximumBytes) else {
            throw HookConfigurationApplicationError.configurationTooLarge(limit: maximumBytes)
        }
        let contents = try readAll(descriptor, maximumBytes: maximumBytes)
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw mappedErrno(operation: "stat-configuration")
        }
        guard fileIdentity(initialStatus) == fileIdentity(finalStatus) else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        return contents
    }

    func writeTemporaryContents(_ data: Data, descriptor: Int32, fileMode: UInt16) throws {
        try withDescriptor(descriptor, operation: "close-temporary") { fileDescriptor in
            guard fchmod(fileDescriptor, mode_t(fileMode)) == 0 else {
                throw mappedErrno(operation: "chmod-temporary")
            }
            try writeAll(data, descriptor: fileDescriptor)
            guard fsync(fileDescriptor) == 0 else {
                throw mappedErrno(operation: "sync-temporary")
            }
        }
    }

    func commitTemporaryFile(
        _ temporaryName: String,
        target: AtomicWriteTarget,
        temporaryExists: inout Bool
    ) throws {
        let current = try inspectFile(
            location: target.location,
            directoryDescriptor: target.directoryDescriptor,
            identityParts: target.identityParts,
            maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
        )
        guard current == target.expected else {
            throw HookConfigurationApplicationError.concurrentModification
        }
        guard renameat(
            target.directoryDescriptor,
            temporaryName,
            target.directoryDescriptor,
            target.location.fileName
        ) == 0 else {
            throw mappedErrno(operation: "rename")
        }
        temporaryExists = false
        guard fsync(target.directoryDescriptor) == 0 else {
            throw mappedErrno(operation: "sync-directory")
        }
    }

    func cleanupTemporaryFile(
        _ temporaryName: String,
        directoryDescriptor: Int32,
        temporaryExists: Bool,
        operationError: any Error
    ) throws -> Never {
        if temporaryExists {
            let unlinkResult = unlinkat(directoryDescriptor, temporaryName, 0)
            let unlinkCode = errno
            if unlinkResult != 0, unlinkCode != ENOENT {
                throw HookConfigurationApplicationError.fileSystemFailure(
                    operation: "cleanup-temporary",
                    code: unlinkCode
                )
            }
        }
        throw operationError
    }
}
