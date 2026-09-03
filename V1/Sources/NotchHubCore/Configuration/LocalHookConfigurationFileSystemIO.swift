import CryptoKit
import Darwin
import Foundation
import NotchHubBridge

extension LocalHookConfigurationFileSystem {
    func readAll(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 16_384))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw mappedErrno(operation: "read") }
            guard result.count + count <= maximumBytes else {
                throw HookConfigurationApplicationError.configurationTooLarge(limit: maximumBytes)
            }
            result.append(buffer, count: count)
        }
    }

    func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw mappedErrno(operation: "write") }
                offset += count
            }
        }
    }

    func withDescriptor<T>(
        _ descriptor: Int32,
        operation: String,
        body: (Int32) throws -> T
    ) throws -> T {
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try body(descriptor))
        } catch {
            outcome = .failure(error)
        }
        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            throw HookConfigurationApplicationError.fileSystemFailure(operation: operation, code: closeCode)
        }
        return try outcome.get()
    }

    func statusAt(directoryDescriptor: Int32, name: String) throws -> stat? {
        var status = stat()
        guard fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw mappedErrno(operation: "stat")
        }
        return status
    }

    func validateDirectory(_ status: stat) throws {
        let kind = status.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw HookConfigurationApplicationError.symbolicLinkRejected
        }
        guard kind == S_IFDIR else { throw HookConfigurationApplicationError.unsupportedFileType }
    }

    func validateOwnedDirectory(_ status: stat) throws {
        try validateDirectory(status)
        guard status.st_uid == geteuid(), status.st_mode & mode_t(0o022) == 0 else {
            throw HookConfigurationApplicationError.permissionDenied
        }
    }

    func validateRegularFile(_ status: stat) throws {
        let kind = status.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw HookConfigurationApplicationError.symbolicLinkRejected
        }
        guard kind == S_IFREG else { throw HookConfigurationApplicationError.unsupportedFileType }
        guard status.st_uid == geteuid() else { throw HookConfigurationApplicationError.permissionDenied }
    }

    func missingSnapshot(
        location: ConfigurationLocation,
        identityParts: [String]
    ) -> HookConfigurationFileSnapshot {
        HookConfigurationFileSnapshot(
            input: HookConfigurationInput(
                homeDirectoryPath: location.homeDirectory.path,
                existingData: nil,
                fileKind: .missing
            ),
            identity: identity(identityParts)
        )
    }

    func identity(_ parts: [String]) -> Data {
        Data(SHA256.hash(data: Data(parts.joined(separator: "|").utf8)))
    }

    func directoryIdentity(_ status: stat) -> String {
        [
            String(status.st_dev),
            String(status.st_ino),
            String(status.st_mode),
            String(status.st_uid),
        ].joined(separator: ":")
    }

    func fileIdentity(_ status: stat) -> String {
        [
            String(status.st_dev), String(status.st_ino), String(status.st_mode),
            String(status.st_uid), String(status.st_size),
            String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    func mappedErrno(operation: String) -> HookConfigurationApplicationError {
        let code = errno
        if code == ELOOP { return .symbolicLinkRejected }
        if code == EACCES || code == EPERM { return .permissionDenied }
        return .fileSystemFailure(operation: operation, code: code)
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
