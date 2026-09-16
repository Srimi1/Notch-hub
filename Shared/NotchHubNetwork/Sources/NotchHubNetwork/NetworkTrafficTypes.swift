// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation

public enum NetworkTrafficState: Sendable, Equatable {
    case measuring
    case live
    case unavailable(message: String)

    public var message: String {
        switch self {
        case .measuring:
            "Measuring…"
        case .live:
            "Live traffic · all apps"
        case let .unavailable(message):
            message
        }
    }

    public var hasReading: Bool {
        self == .live
    }
}

public enum NetworkTrafficSourceError: Error, Sendable, Equatable {
    case systemCall(operation: String, code: Int32)
    case emptyRouteTable
    case invalidInterfaceIndex(Int)
    case interfaceDisappeared(Int)
    case dependencyFailure(component: String, description: String)
    case malformedRouteMessage(
        offset: Int,
        declaredLength: Int,
        requiredLength: Int,
        bufferLength: Int
    )

    public var userMessage: String {
        switch self {
        case .systemCall, .emptyRouteTable, .malformedRouteMessage:
            "Unable to read network traffic"
        case .invalidInterfaceIndex, .interfaceDisappeared:
            "The selected network interface is unavailable"
        case .dependencyFailure:
            "Unable to update network traffic"
        }
    }
}

extension NetworkTrafficSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .systemCall(operation, code):
            "\(operation) failed with errno \(code)"
        case .emptyRouteTable:
            "NET_RT_IFLIST2 returned an empty route table"
        case let .invalidInterfaceIndex(index):
            "Network interface index \(index) cannot be represented by sysctl"
        case let .interfaceDisappeared(index):
            "Network interface index \(index) no longer has readable counters"
        case let .dependencyFailure(component, description):
            "\(component) failed: \(description)"
        case let .malformedRouteMessage(offset, declared, required, bufferLength):
            "Malformed route message at byte \(offset): declared \(declared), "
                + "required \(required), buffer \(bufferLength)"
        }
    }
}

public struct NetworkTrafficSnapshot: Sendable, Equatable {
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let interfaceName: String?
    public let state: NetworkTrafficState
    public let sourceError: NetworkTrafficSourceError?

    public init(
        downloadMbps: Double,
        uploadMbps: Double,
        interfaceName: String?,
        state: NetworkTrafficState,
        sourceError: NetworkTrafficSourceError? = nil
    ) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.interfaceName = interfaceName
        self.state = state
        self.sourceError = sourceError
    }

    public static let paused = NetworkTrafficSnapshot(
        downloadMbps: 0,
        uploadMbps: 0,
        interfaceName: nil,
        state: .unavailable(message: "Network traffic is paused")
    )

    public static let measuring = NetworkTrafficSnapshot(
        downloadMbps: 0,
        uploadMbps: 0,
        interfaceName: nil,
        state: .measuring
    )
}

public struct NetworkInterfaceCounters: Sendable, Equatable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public protocol NetworkCounterSource: Sendable {
    func counters(forInterfaceIndex index: Int) async throws -> NetworkInterfaceCounters?
}

public protocol NetworkPathSource: Sendable {
    func snapshots() async -> AsyncStream<NetworkPathSnapshot>
}

public protocol NetworkTrafficTimeSource: Sendable {
    func now() async -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

public enum NetworkTrafficLifecycleEvent: Sendable, Equatable {
    case willSleep
    case didWake
}

public protocol NetworkTrafficLifecycleSource: Sendable {
    @MainActor func events() -> AsyncStream<NetworkTrafficLifecycleEvent>
}

public protocol NetworkTrafficMonitoring: Sendable {
    func updates() async -> AsyncStream<NetworkTrafficSnapshot>
    func start() async
    func stop() async
}
