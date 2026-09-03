import Darwin
import Foundation

extension LocalBridgeHelperInstallationFileSystem {
    func validateDirectoryComponent(
        descriptor: Int32,
        component: String,
        createMissing: Bool
    ) throws {
        do {
            let status: stat
            if let existing = try statusAt(directoryDescriptor: descriptor, name: component) {
                status = existing
            } else if createMissing {
                guard mkdirat(descriptor, component, mode_t(0o700)) == 0 else {
                    throw mappedErrno(operation: "mkdir")
                }
                guard let created = try statusAt(directoryDescriptor: descriptor, name: component) else {
                    throw BridgeHelperInstallerError.fileSystemFailure(
                        operation: "mkdir-verify",
                        code: ENOENT
                    )
                }
                status = created
            } else {
                throw BridgeHelperInstallerError.fileSystemFailure(operation: "directory", code: ENOENT)
            }
            try validateDirectory(status)
        } catch {
            try closeDescriptorAndThrow(
                descriptor,
                operationError: error
            )
        }
    }

    func descendDirectory(from descriptor: Int32, into component: String) throws -> Int32 {
        let nextDescriptor = openat(
            descriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard nextDescriptor >= 0 else {
            let operationError = mappedErrno(operation: "open-directory")
            try closeDescriptorAndThrow(descriptor, operationError: operationError)
        }

        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            let nextCloseResult = Darwin.close(nextDescriptor)
            let nextCloseCode = errno
            guard nextCloseResult == 0 else {
                throw BridgeHelperInstallerError.fileSystemFailure(
                    operation: "close-directory",
                    code: nextCloseCode
                )
            }
            throw BridgeHelperInstallerError.fileSystemFailure(
                operation: "close-directory",
                code: closeCode
            )
        }
        return nextDescriptor
    }

    func closeDescriptorAndThrow(
        _ descriptor: Int32,
        operationError: any Error
    ) throws -> Never {
        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            throw BridgeHelperInstallerError.fileSystemFailure(
                operation: "close-directory",
                code: closeCode
            )
        }
        throw operationError
    }
}
