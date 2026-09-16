// Adapted and modified from Internet-speed-reader at commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation
import Network

public struct NetworkPathSnapshot: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection
        case unknown
    }

    public struct Interface: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case wifi
            case wiredEthernet
            case cellular
            case loopback
            case tunnel
            case other

            var isPhysical: Bool {
                self == .wifi || self == .wiredEthernet || self == .cellular
            }
        }

        public let name: String
        public let index: Int
        public let kind: Kind
        public let isUsedByPath: Bool

        public init(
            name: String,
            index: Int,
            kind: Kind,
            isUsedByPath: Bool = false
        ) {
            self.name = name
            self.index = index
            self.kind = kind
            self.isUsedByPath = isUsedByPath
        }
    }

    public let status: Status
    public let interfaces: [Interface]
    public let unsatisfiedReason: String?
    public let generation: Int

    public init(
        status: Status,
        interfaces: [Interface],
        unsatisfiedReason: String? = nil,
        generation: Int = 0
    ) {
        self.status = status
        self.interfaces = interfaces
        self.unsatisfiedReason = unsatisfiedReason
        self.generation = generation
    }

    public static let unknown = NetworkPathSnapshot(status: .unknown, interfaces: [])

    public var activeInterface: Interface? {
        NetworkActiveInterfaceSelector.select(from: interfaces)
    }
}

public enum NetworkActiveInterfaceSelector {
    public static let excludedNames: Set<String> = [
        "lo0", "awdl0", "llw0", "anpi0", "anpi1", "anpi2",
        "bridge0", "ap1", "gif0", "stf0",
    ]

    public static func select(
        from interfaces: [NetworkPathSnapshot.Interface]
    ) -> NetworkPathSnapshot.Interface? {
        var seen = Set<Int>()
        let candidates = interfaces
            .filter { seen.insert($0.index).inserted }
            .filter { !excludedNames.contains($0.name) }

        if let physical = candidates.first(where: { $0.kind.isPhysical && $0.isUsedByPath })
            ?? candidates.first(where: { $0.kind.isPhysical }) {
            return physical
        }
        return candidates.first(where: { $0.kind == .tunnel && $0.isUsedByPath })
            ?? candidates.first(where: { $0.kind == .tunnel })
            ?? candidates.first
    }
}

public final class SystemNetworkPathSource: NetworkPathSource, @unchecked Sendable {
    public init() {}

    public func snapshots() async -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.srimi.notchhub.network-path")
            let generation = LockedGeneration()

            monitor.pathUpdateHandler = { path in
                let snapshot = Self.snapshot(from: path, generation: generation.next())
                continuation.yield(snapshot)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    private static func snapshot(from path: NWPath, generation: Int) -> NetworkPathSnapshot {
        let status: NetworkPathSnapshot.Status = switch path.status {
        case .satisfied: .satisfied
        case .unsatisfied: .unsatisfied
        case .requiresConnection: .requiresConnection
        @unknown default: .unknown
        }
        let interfaces = path.availableInterfaces.map { interface in
            NetworkPathSnapshot.Interface(
                name: interface.name,
                index: interface.index,
                kind: kind(for: interface),
                isUsedByPath: path.usesInterfaceType(interface.type)
            )
        }
        return NetworkPathSnapshot(
            status: status,
            interfaces: interfaces,
            unsatisfiedReason: unavailableMessage(for: path),
            generation: generation
        )
    }

    private static func kind(for interface: NWInterface) -> NetworkPathSnapshot.Interface.Kind {
        switch interface.type {
        case .wifi: .wifi
        case .wiredEthernet: .wiredEthernet
        case .cellular: .cellular
        case .loopback: .loopback
        case .other:
            isTunnelName(interface.name) ? .tunnel : .other
        @unknown default: .other
        }
    }

    private static func isTunnelName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains(where: name.hasPrefix)
    }

    private static func unavailableMessage(for path: NWPath) -> String? {
        guard path.status != .satisfied else { return nil }
        guard path.status == .unsatisfied else { return "Network connection is not ready" }
        return switch path.unsatisfiedReason {
        case .cellularDenied: "Cellular networking is off"
        case .wifiDenied: "Wi-Fi is off"
        case .localNetworkDenied: "Local network access is unavailable"
        case .notAvailable: "No network connection"
        default: "No network connection"
        }
    }
}

private final class LockedGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
