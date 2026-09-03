import CryptoKit
import Darwin
import Foundation

public struct LocalBridgeHelperInstallationFileSystem: BridgeHelperInstallationFileSystem {
    public init() {}

    public func stageCopy(
        from sourceURL: URL,
        nextTo destinationURL: URL,
        maximumBytes: Int,
        fileMode: UInt16
    ) throws -> BridgeHelperStagedCopy {
        try validateFileURL(sourceURL)
        try validateFileURL(destinationURL)
        guard fileMode == 0o700 else {
            throw BridgeHelperInstallerError.invalidPath
        }
        let data = try readSource(sourceURL, maximumBytes: maximumBytes)
        let destinationDirectory = destinationURL.deletingLastPathComponent().standardizedFileURL
        let temporaryName = ".notchhub-bridge-\(UUID().uuidString).tmp"
        try withAbsoluteDirectory(
            destinationDirectory,
            createMissing: true,
            requireCurrentOwner: true
        ) { directoryDescriptor in
            try writeStaged(
                data,
                directoryDescriptor: directoryDescriptor,
                name: temporaryName,
                fileMode: fileMode
            )
        }
        return BridgeHelperStagedCopy(
            url: destinationDirectory.appendingPathComponent(temporaryName),
            byteCount: data.count,
            contentDigest: Data(SHA256.hash(data: data))
        )
    }

    public func commit(
        _ stagedCopy: BridgeHelperStagedCopy,
        to destinationURL: URL
    ) throws {
        let stagedParent = stagedCopy.url.deletingLastPathComponent().standardizedFileURL
        let destinationParent = destinationURL.deletingLastPathComponent().standardizedFileURL
        guard stagedParent == destinationParent,
              isTemporaryName(stagedCopy.url.lastPathComponent)
        else {
            throw BridgeHelperInstallerError.invalidPath
        }
        try withAbsoluteDirectory(
            destinationParent,
            createMissing: false,
            requireCurrentOwner: true
        ) { directoryDescriptor in
            let stagedIdentity = try verifyStagedCopy(stagedCopy, directoryDescriptor: directoryDescriptor)
            if let destinationStatus = try statusAt(
                directoryDescriptor: directoryDescriptor,
                name: destinationURL.lastPathComponent
            ) {
                try validateRegularFile(destinationStatus, owner: .current, requiredMode: nil)
            }
            guard let immediatelyBeforeRename = try statusAt(
                directoryDescriptor: directoryDescriptor,
                name: stagedCopy.url.lastPathComponent
            ),
                fileIdentity(immediatelyBeforeRename) == stagedIdentity
            else {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "stage-race", code: ESTALE)
            }
            guard renameat(
                directoryDescriptor,
                stagedCopy.url.lastPathComponent,
                directoryDescriptor,
                destinationURL.lastPathComponent
            ) == 0 else {
                throw mappedErrno(operation: "rename")
            }
            guard fsync(directoryDescriptor) == 0 else {
                throw mappedErrno(operation: "sync-directory")
            }
        }
    }

    public func discard(_ stagedCopy: BridgeHelperStagedCopy) throws {
        guard isTemporaryName(stagedCopy.url.lastPathComponent) else {
            throw BridgeHelperInstallerError.invalidPath
        }
        let parent = stagedCopy.url.deletingLastPathComponent().standardizedFileURL
        try withAbsoluteDirectory(parent, createMissing: false, requireCurrentOwner: true) { descriptor in
            guard unlinkat(descriptor, stagedCopy.url.lastPathComponent, 0) == 0 else {
                if errno == ENOENT {
                    return
                }
                throw mappedErrno(operation: "discard")
            }
        }
    }
}

extension LocalBridgeHelperInstallationFileSystem {
    func readSource(_ sourceURL: URL, maximumBytes: Int) throws -> Data {
        let parent = sourceURL.deletingLastPathComponent().standardizedFileURL
        return try withAbsoluteDirectory(parent, createMissing: false, requireCurrentOwner: false) { descriptor in
            guard let listedStatus = try statusAt(
                directoryDescriptor: descriptor,
                name: sourceURL.lastPathComponent
            ) else {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "source", code: ENOENT)
            }
            try validateRegularFile(listedStatus, owner: .currentOrRoot, requiredMode: nil)
            guard listedStatus.st_size <= Int64(maximumBytes) else {
                throw BridgeHelperInstallerError.sourceTooLarge(limit: maximumBytes)
            }
            let sourceDescriptor = openat(
                descriptor,
                sourceURL.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard sourceDescriptor >= 0 else {
                throw mappedErrno(operation: "open-source")
            }
            return try withDescriptor(sourceDescriptor, operation: "close-source") { fileDescriptor in
                var initialStatus = stat()
                guard fstat(fileDescriptor, &initialStatus) == 0 else {
                    throw mappedErrno(operation: "stat-source")
                }
                try validateRegularFile(initialStatus, owner: .currentOrRoot, requiredMode: nil)
                guard fileIdentity(initialStatus) == fileIdentity(listedStatus) else {
                    throw BridgeHelperInstallerError.fileSystemFailure(operation: "source-race", code: ESTALE)
                }
                let data = try readAll(fileDescriptor, maximumBytes: maximumBytes)
                var finalStatus = stat()
                guard fstat(fileDescriptor, &finalStatus) == 0 else {
                    throw mappedErrno(operation: "stat-source")
                }
                guard fileIdentity(initialStatus) == fileIdentity(finalStatus) else {
                    throw BridgeHelperInstallerError.fileSystemFailure(operation: "source-race", code: ESTALE)
                }
                return data
            }
        }
    }

    func verifyStagedCopy(
        _ stagedCopy: BridgeHelperStagedCopy,
        directoryDescriptor: Int32
    ) throws -> String {
        guard let listedStatus = try statusAt(
            directoryDescriptor: directoryDescriptor,
            name: stagedCopy.url.lastPathComponent
        ) else {
            throw BridgeHelperInstallerError.fileSystemFailure(operation: "commit", code: ENOENT)
        }
        try validateRegularFile(listedStatus, owner: .current, requiredMode: 0o700)
        let descriptor = openat(
            directoryDescriptor,
            stagedCopy.url.lastPathComponent,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-stage")
        }
        return try withDescriptor(descriptor, operation: "close-stage") { fileDescriptor in
            var initialStatus = stat()
            guard fstat(fileDescriptor, &initialStatus) == 0 else {
                throw mappedErrno(operation: "stat-stage")
            }
            try validateRegularFile(initialStatus, owner: .current, requiredMode: 0o700)
            guard fileIdentity(initialStatus) == fileIdentity(listedStatus) else {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "stage-race", code: ESTALE)
            }
            let contents = try readAll(fileDescriptor, maximumBytes: stagedCopy.byteCount)
            var finalStatus = stat()
            guard fstat(fileDescriptor, &finalStatus) == 0 else {
                throw mappedErrno(operation: "stat-stage")
            }
            guard fileIdentity(initialStatus) == fileIdentity(finalStatus),
                  contents.count == stagedCopy.byteCount,
                  Data(SHA256.hash(data: contents)) == stagedCopy.contentDigest
            else {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "stage-race", code: ESTALE)
            }
            return fileIdentity(finalStatus)
        }
    }

    func writeStaged(
        _ data: Data,
        directoryDescriptor: Int32,
        name: String,
        fileMode: UInt16
    ) throws {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(fileMode)
        )
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-stage")
        }
        do {
            try withDescriptor(descriptor, operation: "close-stage") { fileDescriptor in
                guard fchmod(fileDescriptor, mode_t(fileMode)) == 0 else {
                    throw mappedErrno(operation: "chmod-stage")
                }
                try writeAll(data, descriptor: fileDescriptor)
                guard fsync(fileDescriptor) == 0 else {
                    throw mappedErrno(operation: "sync-stage")
                }
            }
        } catch {
            let operationError = error
            let unlinkResult = unlinkat(directoryDescriptor, name, 0)
            let unlinkCode = errno
            if unlinkResult != 0, unlinkCode != ENOENT {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "cleanup-stage", code: unlinkCode)
            }
            throw operationError
        }
    }

    func withAbsoluteDirectory<T>(
        _ url: URL,
        createMissing: Bool,
        requireCurrentOwner: Bool,
        operation: (Int32) throws -> T
    ) throws -> T {
        try validateFileURL(url)
        let descriptor = try openAbsoluteDirectory(url, createMissing: createMissing)
        return try withDescriptor(descriptor, operation: "close-directory") { directoryDescriptor in
            var status = stat()
            guard fstat(directoryDescriptor, &status) == 0 else {
                throw mappedErrno(operation: "stat-directory")
            }
            try validateDirectory(status)
            if requireCurrentOwner {
                try validateOwnedNode(status)
            }
            return try operation(directoryDescriptor)
        }
    }

    func openAbsoluteDirectory(_ url: URL, createMissing: Bool) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-root")
        }
        for component in url.pathComponents.dropFirst() {
            try validateDirectoryComponent(
                descriptor: descriptor,
                component: component,
                createMissing: createMissing
            )
            descriptor = try descendDirectory(from: descriptor, into: component)
        }
        return descriptor
    }
}
