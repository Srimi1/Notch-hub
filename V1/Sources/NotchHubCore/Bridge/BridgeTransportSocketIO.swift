import Darwin
import Foundation

enum BridgeSocketIO {
    static func makeStreamSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw BridgeTransportError.posix(operation: "socket", code: errno)
        }
        do {
            try configure(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    static func connect(
        descriptor: Int32,
        path: String,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws {
        let result = try BridgeUnixSocketAddress.withAddress(path: path) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        if result == 0 {
            return
        }
        guard errno == EINPROGRESS else {
            throw BridgeTransportError.posix(operation: "connect", code: errno)
        }
        try await wait(
            descriptor: descriptor,
            events: Int16(POLLOUT),
            deadlineMilliseconds: deadlineMilliseconds,
            clock: clock
        )
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            throw BridgeTransportError.posix(operation: "getsockopt", code: errno)
        }
        guard socketError == 0 else {
            throw BridgeTransportError.posix(operation: "connect", code: socketError)
        }
    }

    static func bindAndListen(descriptor: Int32, path: String) throws {
        let result = try BridgeUnixSocketAddress.withAddress(path: path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard result == 0 else {
            throw BridgeTransportError.posix(operation: "bind", code: errno)
        }
        try BridgeSocketPathSecurity.secureSocketNode(path)
        guard Darwin.listen(descriptor, 8) == 0 else {
            throw BridgeTransportError.posix(operation: "listen", code: errno)
        }
    }

    static func accept(
        listener: Int32,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws -> Int32 {
        while true {
            try await wait(
                descriptor: listener,
                events: Int16(POLLIN),
                deadlineMilliseconds: deadlineMilliseconds,
                clock: clock
            )
            let descriptor = Darwin.accept(listener, nil, nil)
            if descriptor >= 0 {
                do {
                    try configure(descriptor)
                    return descriptor
                } catch {
                    _ = close(descriptor)
                    throw error
                }
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw BridgeTransportError.posix(operation: "accept", code: errno)
            }
        }
    }

    static func readFrameBody(
        descriptor: Int32,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws -> Data {
        let prefix = try await readExact(
            descriptor: descriptor,
            count: 4,
            deadlineMilliseconds: deadlineMilliseconds,
            clock: clock
        )
        let length = try BridgeTransportFraming.decodedLength(
            prefix,
            maximumBytes: BridgeTransportConstants.maximumFrameBytes
        )
        return try await readExact(
            descriptor: descriptor,
            count: length,
            deadlineMilliseconds: deadlineMilliseconds,
            clock: clock
        )
    }

    static func writeFrame<Value: Encodable>(
        _ value: Value,
        descriptor: Int32,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws {
        let data = try BridgeTransportFraming.framedData(for: value)
        try await writeAll(
            data,
            descriptor: descriptor,
            deadlineMilliseconds: deadlineMilliseconds,
            clock: clock
        )
    }

    static func closeDescriptor(_ descriptor: Int32) {
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = close(descriptor)
    }

    private static func configure(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw BridgeTransportError.posix(operation: "fcntl", code: errno)
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            throw BridgeTransportError.posix(operation: "fcntl close-on-exec", code: errno)
        }
        var enabled: Int32 = 1
        let length = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, length) == 0 else {
            throw BridgeTransportError.posix(operation: "setsockopt", code: errno)
        }
    }

    private static func readExact(
        descriptor: Int32,
        count: Int,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try await wait(
                descriptor: descriptor,
                events: Int16(POLLIN),
                deadlineMilliseconds: deadlineMilliseconds,
                clock: clock
            )
            let requested = min(4096, count - result.count)
            var buffer = [UInt8](repeating: 0, count: requested)
            let received = Darwin.recv(descriptor, &buffer, requested, 0)
            if received > 0 {
                result.append(contentsOf: buffer.prefix(received))
            } else if received == 0 {
                throw BridgeTransportError.unavailable
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                throw BridgeTransportError.posix(operation: "recv", code: errno)
            }
        }
        return result
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws {
        var offset = 0
        while offset < data.count {
            try await wait(
                descriptor: descriptor,
                events: Int16(POLLOUT),
                deadlineMilliseconds: deadlineMilliseconds,
                clock: clock
            )
            let sent = data.withUnsafeBytes { bytes in
                let sent = Darwin.send(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset, 0)
                return sent
            }
            if sent > 0 {
                offset += sent
            } else if sent == 0 {
                throw BridgeTransportError.unavailable
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                throw BridgeTransportError.posix(operation: "send", code: errno)
            }
        }
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        deadlineMilliseconds: Int64,
        clock: any BridgeTransportClock
    ) async throws {
        while true {
            guard !Task.isCancelled else {
                throw BridgeTransportError.cancelled
            }
            let remaining = deadlineMilliseconds - clock.nowMilliseconds()
            guard remaining > 0 else {
                throw BridgeTransportError.deadlineExceeded
            }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let pollSlice = min(remaining, 100)
            let result = Darwin.poll(&pollDescriptor, 1, Int32(pollSlice))
            if result > 0, pollDescriptor.revents & events != 0 {
                return
            }
            if result == 0 {
                await Task.yield()
                continue
            }
            if result < 0, errno == EINTR {
                await Task.yield()
                continue
            }
            let errorEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if pollDescriptor.revents & errorEvents != 0 {
                throw BridgeTransportError.unavailable
            }
            if result < 0 {
                throw BridgeTransportError.posix(operation: "poll", code: errno)
            }
        }
    }
}
