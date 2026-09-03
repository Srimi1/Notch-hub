import Darwin
import Foundation

public enum SecureFileIOError: Error, Equatable, Sendable {
    case invalidFileName
    case directoryUnavailable(Int32)
    case symbolicLinkRejected
    case openFailed(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)
    case syncFailed(Int32)
    case closeFailed(Int32)
    case replaceFailed(Int32)
    case oversizedFile(maximumBytes: Int)
}

public enum SecureFileIO {
    public static func read(
        from fileURL: URL,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else {
            throw SecureFileIOError.oversizedFile(maximumBytes: maximumBytes)
        }
        return try withDirectoryDescriptor(for: fileURL) { directoryDescriptor, fileName in
            try read(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName,
                maximumBytes: maximumBytes
            )
        }
    }

    public static func writeAtomically(
        _ data: Data,
        to fileURL: URL
    ) throws {
        try createParentDirectory(for: fileURL)
        try withDirectoryDescriptor(for: fileURL) { directoryDescriptor, fileName in
            try rejectExistingSymbolicLink(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            )
            try writeTemporaryAndReplace(
                data,
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            )
        }
    }

    public static func remove(from fileURL: URL) throws {
        try withDirectoryDescriptor(for: fileURL) { directoryDescriptor, fileName in
            try rejectExistingSymbolicLink(
                directoryDescriptor: directoryDescriptor,
                fileName: fileName
            )
            if unlinkat(directoryDescriptor, fileName, 0) != 0, errno != ENOENT {
                throw SecureFileIOError.replaceFailed(errno)
            }
            if fsync(directoryDescriptor) != 0 {
                throw SecureFileIOError.syncFailed(errno)
            }
        }
    }

    private static func createParentDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SecureFileIOError.directoryUnavailable(errno)
        }
    }

    private static func withDirectoryDescriptor<T>(
        for fileURL: URL,
        operation: (Int32, String) throws -> T
    ) throws -> T {
        let fileName = fileURL.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/") else {
            throw SecureFileIOError.invalidFileName
        }

        let directoryPath = fileURL.deletingLastPathComponent().path
        var directoryDescriptor = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP {
                throw SecureFileIOError.symbolicLinkRejected
            }
            throw SecureFileIOError.directoryUnavailable(errno)
        }

        do {
            let result = try operation(directoryDescriptor, fileName)
            try closeOwnedDescriptor(&directoryDescriptor)
            return result
        } catch {
            relinquishDescriptor(&directoryDescriptor)
            throw error
        }
    }

    private static func rejectExistingSymbolicLink(
        directoryDescriptor: Int32,
        fileName: String
    ) throws {
        var status = stat()
        if fstatat(directoryDescriptor, fileName, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            if status.st_mode & S_IFMT == S_IFLNK {
                throw SecureFileIOError.symbolicLinkRejected
            }
            return
        }
        guard errno == ENOENT else {
            throw SecureFileIOError.openFailed(errno)
        }
    }

    private static func read(
        directoryDescriptor: Int32,
        fileName: String,
        maximumBytes: Int
    ) throws -> Data? {
        var descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw SecureFileIOError.symbolicLinkRejected
            }
            throw SecureFileIOError.openFailed(errno)
        }

        do {
            let data = try readAll(from: descriptor, maximumBytes: maximumBytes)
            try closeOwnedDescriptor(&descriptor)
            return data
        } catch {
            relinquishDescriptor(&descriptor)
            throw error
        }
    }

    private static func readAll(
        from descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, maximumBytes))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return result
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw SecureFileIOError.readFailed(errno)
            }
            guard result.count + count <= maximumBytes else {
                throw SecureFileIOError.oversizedFile(maximumBytes: maximumBytes)
            }
            result.append(buffer, count: count)
        }
    }

    private static func writeTemporaryAndReplace(
        _ data: Data,
        directoryDescriptor: Int32,
        fileName: String
    ) throws {
        let temporaryName = ".notchhub-\(UUID().uuidString).tmp"
        var descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SecureFileIOError.openFailed(errno)
        }

        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw SecureFileIOError.syncFailed(errno)
            }
            try closeOwnedDescriptor(&descriptor)
        } catch {
            relinquishDescriptor(&descriptor)
            throw error
        }

        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, fileName) == 0 else {
            throw SecureFileIOError.replaceFailed(errno)
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw SecureFileIOError.syncFailed(errno)
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SecureFileIOError.writeFailed(errno)
                }
                guard count > 0 else {
                    throw SecureFileIOError.writeFailed(EIO)
                }
                offset += count
            }
        }
    }

    private static func closeOwnedDescriptor(_ descriptor: inout Int32) throws {
        let ownedDescriptor = descriptor
        descriptor = -1
        guard Darwin.close(ownedDescriptor) == 0 else {
            throw SecureFileIOError.closeFailed(errno)
        }
    }

    private static func relinquishDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        let ownedDescriptor = descriptor
        descriptor = -1
        _ = Darwin.close(ownedDescriptor)
    }
}
