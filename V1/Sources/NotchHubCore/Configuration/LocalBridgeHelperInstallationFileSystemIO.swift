import Darwin
import Foundation

extension LocalBridgeHelperInstallationFileSystem {
    enum OwnerPolicy {
        case current
        case currentOrRoot
    }

    func withDescriptor<T>(
        _ descriptor: Int32,
        operation: String,
        body: (Int32) throws -> T
    ) throws -> T {
        let outcome: Result<T, any Error>
        do {
            outcome = try .success(body(descriptor))
        } catch {
            outcome = .failure(error)
        }
        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        guard closeResult == 0 else {
            throw BridgeHelperInstallerError.fileSystemFailure(operation: operation, code: closeCode)
        }
        return try outcome.get()
    }

    func readAll(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 16384))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return result
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { throw mappedErrno(operation: "read-source") }
            guard result.count + count <= maximumBytes else {
                throw BridgeHelperInstallerError.sourceTooLarge(limit: maximumBytes)
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
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw mappedErrno(operation: "write-stage") }
                offset += count
            }
        }
    }

    func statusAt(directoryDescriptor: Int32, name: String) throws -> stat? {
        var status = stat()
        guard fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw mappedErrno(operation: "stat")
        }
        return status
    }

    func validateDirectory(_ status: stat) throws {
        let kind = status.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw BridgeHelperInstallerError.symbolicLinkRejected
        }
        guard kind == S_IFDIR else { throw BridgeHelperInstallerError.unsupportedFileType }
    }

    func validateRegularFile(
        _ status: stat,
        owner: OwnerPolicy,
        requiredMode: UInt16?
    ) throws {
        let kind = status.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw BridgeHelperInstallerError.symbolicLinkRejected
        }
        guard kind == S_IFREG else { throw BridgeHelperInstallerError.unsupportedFileType }
        let ownerIsValid = switch owner {
        case .current: status.st_uid == geteuid()
        case .currentOrRoot: status.st_uid == geteuid() || status.st_uid == 0
        }
        guard ownerIsValid, status.st_mode & mode_t(0o022) == 0 else {
            throw BridgeHelperInstallerError.permissionDenied
        }
        if let requiredMode, status.st_mode & mode_t(0o777) != mode_t(requiredMode) {
            throw BridgeHelperInstallerError.permissionDenied
        }
    }

    func validateOwnedNode(_ status: stat) throws {
        guard status.st_uid == geteuid(), status.st_mode & mode_t(0o022) == 0 else {
            throw BridgeHelperInstallerError.permissionDenied
        }
    }

    func validateFileURL(_ url: URL) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("\0"),
              url.standardizedFileURL.path != "/"
        else {
            throw BridgeHelperInstallerError.invalidPath
        }
    }

    func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".notchhub-bridge-") && name.hasSuffix(".tmp") && !name.contains("/")
    }

    func fileIdentity(_ status: stat) -> String {
        [
            String(status.st_dev), String(status.st_ino), String(status.st_mode),
            String(status.st_uid), String(status.st_size),
            String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    func mappedErrno(operation: String) -> BridgeHelperInstallerError {
        let code = errno
        if code == ELOOP {
            return .symbolicLinkRejected
        }
        if code == EACCES || code == EPERM {
            return .permissionDenied
        }
        return .fileSystemFailure(operation: operation, code: code)
    }
}
