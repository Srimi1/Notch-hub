// NotchHub lifecycle integration based on Internet-speed-reader commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import AppKit
import Foundation

public struct WorkspaceNetworkTrafficLifecycleSource: NetworkTrafficLifecycleSource {
    public init() {}

    @MainActor
    public func events() -> AsyncStream<NetworkTrafficLifecycleEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let observation = WorkspaceLifecycleObservation(continuation: continuation)
            observation.start()
            continuation.onTermination = { _ in
                Task { @MainActor in
                    observation.stop()
                }
            }
        }
    }
}

public struct EmptyNetworkTrafficLifecycleSource: NetworkTrafficLifecycleSource {
    public init() {}

    @MainActor
    public func events() -> AsyncStream<NetworkTrafficLifecycleEvent> {
        AsyncStream { _ in }
    }
}

@MainActor
private final class WorkspaceLifecycleObservation: @unchecked Sendable {
    private let continuation: AsyncStream<NetworkTrafficLifecycleEvent>.Continuation
    private let center = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []

    init(continuation: AsyncStream<NetworkTrafficLifecycleEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.willSleep)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.didWake)
        })
    }

    func stop() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}
