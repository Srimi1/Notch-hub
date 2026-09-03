import CryptoKit
import Darwin
import Foundation

public struct LocalHookConfigurationFileSystem: HookConfigurationFileSystem {
    public init() {}

    public func inspect(
        provider: HookConfigurationProvider,
        homeDirectory: URL,
        maximumBytes: Int
    ) throws -> HookConfigurationFileSnapshot {
        let location = try ConfigurationLocation(provider: provider, homeDirectory: homeDirectory)
        return try withHomeDirectory(location) { homeDescriptor, homeIdentity in
            guard let directoryStatus = try statusAt(
                directoryDescriptor: homeDescriptor,
                name: location.configurationDirectoryName
            ) else {
                return missingSnapshot(location: location, identityParts: homeIdentity + ["parent-missing"])
            }
            try validateOwnedDirectory(directoryStatus)
            return try withChildDirectory(
                parentDescriptor: homeDescriptor,
                name: location.configurationDirectoryName
            ) { configurationDescriptor in
                try inspectFile(
                    location: location,
                    directoryDescriptor: configurationDescriptor,
                    identityParts: homeIdentity + [directoryIdentity(directoryStatus)],
                    maximumBytes: maximumBytes
                )
            }
        }
    }

    public func replaceAtomically(
        _ data: Data,
        provider: HookConfigurationProvider,
        homeDirectory: URL,
        expected: HookConfigurationFileSnapshot,
        fileMode: UInt16
    ) throws {
        guard fileMode == 0o600 else {
            throw HookConfigurationApplicationError.invalidAtomicWrite
        }
        let location = try ConfigurationLocation(provider: provider, homeDirectory: homeDirectory)
        try withHomeDirectory(location) { homeDescriptor, homeIdentity in
            let existingDirectory = try statusAt(
                directoryDescriptor: homeDescriptor,
                name: location.configurationDirectoryName
            )
            if let existingDirectory {
                try validateOwnedDirectory(existingDirectory)
                try withChildDirectory(
                    parentDescriptor: homeDescriptor,
                    name: location.configurationDirectoryName
                ) { configurationDescriptor in
                    let identityParts = homeIdentity + [directoryIdentity(existingDirectory)]
                    let current = try inspectFile(
                        location: location,
                        directoryDescriptor: configurationDescriptor,
                        identityParts: identityParts,
                        maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
                    )
                    guard current == expected else {
                        throw HookConfigurationApplicationError.concurrentModification
                    }
                    try writeAtomically(
                        data,
                        location: location,
                        directoryDescriptor: configurationDescriptor,
                        identityParts: identityParts,
                        expected: current,
                        fileMode: fileMode
                    )
                }
                return
            }

            let missing = missingSnapshot(
                location: location,
                identityParts: homeIdentity + ["parent-missing"]
            )
            guard missing == expected else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            guard mkdirat(homeDescriptor, location.configurationDirectoryName, mode_t(0o700)) == 0 else {
                if errno == EEXIST {
                    throw HookConfigurationApplicationError.concurrentModification
                }
                throw mappedErrno(operation: "mkdir")
            }
            guard let createdStatus = try statusAt(
                directoryDescriptor: homeDescriptor,
                name: location.configurationDirectoryName
            ) else {
                throw HookConfigurationApplicationError.fileSystemFailure(operation: "mkdir-verify", code: ENOENT)
            }
            try validateOwnedDirectory(createdStatus)
            try withChildDirectory(
                parentDescriptor: homeDescriptor,
                name: location.configurationDirectoryName
            ) { configurationDescriptor in
                let identityParts = homeIdentity + [directoryIdentity(createdStatus)]
                let expectedInCreatedDirectory = try inspectFile(
                    location: location,
                    directoryDescriptor: configurationDescriptor,
                    identityParts: identityParts,
                    maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
                )
                guard expectedInCreatedDirectory.input.fileKind == .missing else {
                    throw HookConfigurationApplicationError.concurrentModification
                }
                try writeAtomically(
                    data,
                    location: location,
                    directoryDescriptor: configurationDescriptor,
                    identityParts: identityParts,
                    expected: expectedInCreatedDirectory,
                    fileMode: fileMode
                )
            }
        }
    }
}

extension LocalHookConfigurationFileSystem {
    struct ConfigurationLocation {
        let homeDirectory: URL
        let configurationDirectoryName: String
        let fileName: String

        init(provider: HookConfigurationProvider, homeDirectory: URL) throws {
            guard homeDirectory.isFileURL,
                  homeDirectory.path.hasPrefix("/"),
                  !homeDirectory.path.contains("\0")
            else {
                throw HookConfigurationApplicationError.invalidHomeDirectory
            }
            let standardizedHome = homeDirectory.standardizedFileURL
            let components = provider.relativeConfigurationPath.split(separator: "/").map(String.init)
            guard standardizedHome.path != "/", components.count == 2 else {
                throw HookConfigurationApplicationError.invalidHomeDirectory
            }
            self.homeDirectory = standardizedHome
            self.configurationDirectoryName = components[0]
            self.fileName = components[1]
        }
    }

    func withHomeDirectory<T>(
        _ location: ConfigurationLocation,
        operation: (Int32, [String]) throws -> T
    ) throws -> T {
        let opened = try openAbsoluteDirectory(location.homeDirectory)
        return try withDescriptor(opened.descriptor, operation: "close-home") { descriptor in
            try operation(descriptor, opened.identityParts)
        }
    }

    func openAbsoluteDirectory(_ url: URL) throws -> (descriptor: Int32, identityParts: [String]) {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-root")
        }
        var identityParts: [String] = []
        for component in url.pathComponents.dropFirst() {
            let status: stat
            do {
                guard let resolvedStatus = try statusAt(directoryDescriptor: descriptor, name: component) else {
                    throw HookConfigurationApplicationError.invalidHomeDirectory
                }
                if resolvedStatus.st_mode & S_IFMT == S_IFLNK {
                    throw HookConfigurationApplicationError.fileSystemFailure(
                        operation: "debug-ancestor-\(component)",
                        code: Int32(resolvedStatus.st_mode)
                    )
                }
                try validateDirectory(resolvedStatus)
                status = resolvedStatus
            } catch {
                let operationError = error
                let closeResult = Darwin.close(descriptor)
                let closeCode = errno
                if closeResult != 0 {
                    throw HookConfigurationApplicationError.fileSystemFailure(
                        operation: "close-directory",
                        code: closeCode
                    )
                }
                throw operationError
            }
            let nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if nextDescriptor < 0 {
                let operationError = mappedErrno(operation: "open-directory")
                let closeResult = Darwin.close(descriptor)
                let closeCode = errno
                if closeResult != 0 {
                    throw HookConfigurationApplicationError.fileSystemFailure(
                        operation: "close-directory",
                        code: closeCode
                    )
                }
                throw operationError
            }
            let closeResult = Darwin.close(descriptor)
            let closeCode = errno
            if closeResult != 0 {
                let nextCloseResult = Darwin.close(nextDescriptor)
                let nextCloseCode = errno
                if nextCloseResult != 0 {
                    throw HookConfigurationApplicationError.fileSystemFailure(
                        operation: "close-directory",
                        code: nextCloseCode
                    )
                }
                throw HookConfigurationApplicationError.fileSystemFailure(
                    operation: "close-directory",
                    code: closeCode
                )
            }
            descriptor = nextDescriptor
            identityParts.append(directoryIdentity(status))
        }
        var homeStatus = stat()
        guard fstat(descriptor, &homeStatus) == 0 else {
            let statusCode = errno
            let closeResult = Darwin.close(descriptor)
            let closeCode = errno
            if closeResult != 0 {
                throw HookConfigurationApplicationError.fileSystemFailure(operation: "close-home", code: closeCode)
            }
            throw HookConfigurationApplicationError.fileSystemFailure(operation: "stat-home", code: statusCode)
        }
        do {
            try validateOwnedDirectory(homeStatus)
        } catch {
            let operationError = error
            let closeResult = Darwin.close(descriptor)
            let closeCode = errno
            if closeResult != 0 {
                throw HookConfigurationApplicationError.fileSystemFailure(operation: "close-home", code: closeCode)
            }
            throw operationError
        }
        return (descriptor, identityParts)
    }

    func withChildDirectory<T>(
        parentDescriptor: Int32,
        name: String,
        operation: (Int32) throws -> T
    ) throws -> T {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-configuration-directory")
        }
        return try withDescriptor(descriptor, operation: "close-configuration-directory", body: operation)
    }

    func inspectFile(
        location: ConfigurationLocation,
        directoryDescriptor: Int32,
        identityParts: [String],
        maximumBytes: Int
    ) throws -> HookConfigurationFileSnapshot {
        guard let listedStatus = try statusAt(
            directoryDescriptor: directoryDescriptor,
            name: location.fileName
        ) else {
            return missingSnapshot(location: location, identityParts: identityParts + ["file-missing"])
        }
        try validateRegularFile(listedStatus)
        let descriptor = openat(
            directoryDescriptor,
            location.fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw mappedErrno(operation: "open-configuration")
        }
        let data = try withDescriptor(descriptor, operation: "close-configuration") { fileDescriptor in
            var initialStatus = stat()
            guard fstat(fileDescriptor, &initialStatus) == 0 else {
                throw mappedErrno(operation: "stat-configuration")
            }
            try validateRegularFile(initialStatus)
            guard fileIdentity(initialStatus) == fileIdentity(listedStatus) else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            guard initialStatus.st_size <= Int64(maximumBytes) else {
                throw HookConfigurationApplicationError.configurationTooLarge(limit: maximumBytes)
            }
            let contents = try readAll(fileDescriptor, maximumBytes: maximumBytes)
            var finalStatus = stat()
            guard fstat(fileDescriptor, &finalStatus) == 0 else {
                throw mappedErrno(operation: "stat-configuration")
            }
            guard fileIdentity(initialStatus) == fileIdentity(finalStatus) else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            return contents
        }
        let input = HookConfigurationInput(
            homeDirectoryPath: location.homeDirectory.path,
            existingData: data,
            fileKind: .regularFile
        )
        let digest = SHA256.hash(data: data).hexString
        return HookConfigurationFileSnapshot(
            input: input,
            identity: identity(identityParts + [fileIdentity(listedStatus), digest])
        )
    }

    func writeAtomically(
        _ data: Data,
        location: ConfigurationLocation,
        directoryDescriptor: Int32,
        identityParts: [String],
        expected: HookConfigurationFileSnapshot,
        fileMode: UInt16
    ) throws {
        let temporaryName = ".notchhub-v1-\(UUID().uuidString).tmp"
        let temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(fileMode)
        )
        guard temporaryDescriptor >= 0 else {
            throw mappedErrno(operation: "open-temporary")
        }
        var temporaryExists = true
        do {
            try withDescriptor(temporaryDescriptor, operation: "close-temporary") { descriptor in
                guard fchmod(descriptor, mode_t(fileMode)) == 0 else {
                    throw mappedErrno(operation: "chmod-temporary")
                }
                try writeAll(data, descriptor: descriptor)
                guard fsync(descriptor) == 0 else {
                    throw mappedErrno(operation: "sync-temporary")
                }
            }
            let immediatelyBeforeRename = try inspectFile(
                location: location,
                directoryDescriptor: directoryDescriptor,
                identityParts: identityParts,
                maximumBytes: HookConfigurationPlanner.maximumConfigurationBytes
            )
            guard immediatelyBeforeRename == expected else {
                throw HookConfigurationApplicationError.concurrentModification
            }
            guard renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                location.fileName
            ) == 0 else {
                throw mappedErrno(operation: "rename")
            }
            temporaryExists = false
            guard fsync(directoryDescriptor) == 0 else {
                throw mappedErrno(operation: "sync-directory")
            }
        } catch {
            let operationError = error
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

}
