import CryptoKit
import Darwin
import Foundation
import NotchHubBridge

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
        let request = ReplacementRequest(
            data: data,
            location: location,
            expected: expected,
            fileMode: fileMode
        )
        try withHomeDirectory(location) { homeDescriptor, homeIdentity in
            try replaceInHomeDirectory(
                request,
                homeDescriptor: homeDescriptor,
                homeIdentity: homeIdentity
            )
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

    struct ReplacementRequest {
        let data: Data
        let location: ConfigurationLocation
        let expected: HookConfigurationFileSnapshot
        let fileMode: UInt16
    }

    struct AtomicWriteTarget {
        let location: ConfigurationLocation
        let directoryDescriptor: Int32
        let identityParts: [String]
        let expected: HookConfigurationFileSnapshot
        let fileMode: UInt16
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
            let status = try validatedAncestorStatus(descriptor: descriptor, component: component)
            descriptor = try descend(from: descriptor, into: component)
            identityParts.append(directoryIdentity(status))
        }
        try validateHomeDescriptor(descriptor)
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
            try readVerifiedConfiguration(
                fileDescriptor,
                listedStatus: listedStatus,
                maximumBytes: maximumBytes
            )
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
        target: AtomicWriteTarget
    ) throws {
        let temporaryName = ".notchhub-v1-\(UUID().uuidString).tmp"
        let temporaryDescriptor = openat(
            target.directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(target.fileMode)
        )
        guard temporaryDescriptor >= 0 else {
            throw mappedErrno(operation: "open-temporary")
        }
        var temporaryExists = true
        do {
            try writeTemporaryContents(data, descriptor: temporaryDescriptor, fileMode: target.fileMode)
            try commitTemporaryFile(
                temporaryName,
                target: target,
                temporaryExists: &temporaryExists
            )
        } catch {
            try cleanupTemporaryFile(
                temporaryName,
                directoryDescriptor: target.directoryDescriptor,
                temporaryExists: temporaryExists,
                operationError: error
            )
        }
    }
}
