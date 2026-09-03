import Darwin
import Foundation

public enum BridgeTransportPaths {
    public static func defaultBridgeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchHub/V1/Bridge", isDirectory: true)
    }

    public static func defaultSocketPath() -> String {
        defaultBridgeDirectory()
            .appendingPathComponent("bridge-v1.sock", isDirectory: false)
            .path
    }

    public static func defaultHelperExecutablePath() -> String {
        defaultBridgeDirectory()
            .appendingPathComponent("NotchHubHookBridge", isDirectory: false)
            .path
    }
}

enum BridgeSocketPathSecurity {
    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw BridgeTransportError.invalidSocketPath
        }
        let byteCount = path.utf8CString.count
        guard byteCount <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw BridgeTransportError.invalidSocketPath
        }
    }

    static func prepareServerPath(_ path: String) throws {
        try validatePath(path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try prepareDirectory(directory)
        try rejectExistingNode(path)
    }

    static func secureSocketNode(_ path: String) throws {
        guard chmod(path, mode_t(0o600)) == 0 else {
            throw BridgeTransportError.posix(operation: "chmod socket", code: errno)
        }
        try validateSocketNode(path)
    }

    static func validateClientSocket(_ path: String) throws {
        try validatePath(path)
        try validateSocketNode(path)
    }

    static func removeOwnedSocket(_ path: String) {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            return
        }
        let isSocket = (information.st_mode & S_IFMT) == S_IFSOCK
        guard isSocket, information.st_uid == getuid() else {
            return
        }
        _ = unlink(path)
    }

    private static func prepareDirectory(_ path: String) throws {
        var information = stat()
        if lstat(path, &information) != 0 {
            guard errno == ENOENT else {
                throw BridgeTransportError.posix(operation: "lstat socket directory", code: errno)
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw BridgeTransportError.unavailable
            }
            guard lstat(path, &information) == 0 else {
                throw BridgeTransportError.posix(operation: "lstat socket directory", code: errno)
            }
        }
        let isDirectory = (information.st_mode & S_IFMT) == S_IFDIR
        guard isDirectory, information.st_uid == getuid() else {
            throw BridgeTransportError.socketPathConflict
        }
        guard chmod(path, mode_t(0o700)) == 0 else {
            throw BridgeTransportError.posix(operation: "chmod socket directory", code: errno)
        }
    }

    private static func rejectExistingNode(_ path: String) throws {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            guard errno == ENOENT else {
                throw BridgeTransportError.posix(operation: "lstat socket", code: errno)
            }
            return
        }
        throw BridgeTransportError.socketPathConflict
    }

    private static func validateSocketNode(_ path: String) throws {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            throw BridgeTransportError.unavailable
        }
        let isSocket = (information.st_mode & S_IFMT) == S_IFSOCK
        guard isSocket, information.st_uid == getuid() else {
            throw BridgeTransportError.socketPathConflict
        }
        guard (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw BridgeTransportError.insecureSocketPermissions
        }
    }
}

enum BridgeUnixSocketAddress {
    static func withAddress<Result>(
        path: String,
        body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        try BridgeSocketPathSecurity.validatePath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
