import Darwin
import Foundation

extension LocalHookConfigurationFileSystem {
    func validatedAncestorStatus(descriptor: Int32, component: String) throws -> stat {
        do {
            guard let status = try statusAt(directoryDescriptor: descriptor, name: component) else {
                throw HookConfigurationApplicationError.invalidHomeDirectory
            }
            try validateDirectory(status)
            return status
        } catch {
            try closeDescriptorAndThrow(
                descriptor,
                operation: "close-directory",
                operationError: error
            )
        }
    }

    func descend(from descriptor: Int32, into component: String) throws -> Int32 {
        let nextDescriptor = openat(
            descriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard nextDescriptor >= 0 else {
            let operationError = mappedErrno(operation: "open-directory")
            try closeDescriptorAndThrow(
                descriptor,
                operation: "close-directory",
                operationError: operationError
            )
        }

        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            let nextCloseResult = Darwin.close(nextDescriptor)
            let nextCloseCode = errno
            guard nextCloseResult == 0 else {
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
        return nextDescriptor
    }

    func validateHomeDescriptor(_ descriptor: Int32) throws {
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw mappedErrno(operation: "stat-home")
            }
            try validateOwnedDirectory(status)
        } catch {
            try closeDescriptorAndThrow(
                descriptor,
                operation: "close-home",
                operationError: error
            )
        }
    }

    func closeDescriptorAndThrow(
        _ descriptor: Int32,
        operation: String,
        operationError: any Error
    ) throws -> Never {
        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            throw HookConfigurationApplicationError.fileSystemFailure(
                operation: operation,
                code: closeCode
            )
        }
        throw operationError
    }
}
