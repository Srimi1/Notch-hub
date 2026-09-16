// NotchHub presentation integration based on Internet-speed-reader commit c5e0f627.
// Licensed under Apache-2.0; see LICENSE and UPSTREAM.md in this package.

import Foundation
import Observation

@MainActor
@Observable
public final class NetworkTrafficModel {
    public private(set) var snapshot: NetworkTrafficSnapshot
    public private(set) var isRunning = false

    @ObservationIgnored private let monitor: any NetworkTrafficMonitoring
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?

    public var downloadMbps: Double { snapshot.downloadMbps }
    public var uploadMbps: Double { snapshot.uploadMbps }
    public var interfaceName: String? { snapshot.interfaceName }
    public var state: NetworkTrafficState { snapshot.state }
    public var sourceError: NetworkTrafficSourceError? { snapshot.sourceError }

    public init(monitor: any NetworkTrafficMonitoring = NetworkTrafficMonitor()) {
        self.monitor = monitor
        snapshot = .paused
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        snapshot = .measuring
        let identifier = UUID()
        sessionID = identifier
        enqueueStart(sessionID: identifier)
    }

    public func stop() {
        guard isRunning || updateTask != nil else { return }
        isRunning = false
        sessionID = nil
        updateTask?.cancel()
        updateTask = nil
        snapshot = .paused
        enqueueStop()
    }

    private func subscribe(sessionID: UUID) {
        let monitor = monitor
        updateTask = Task { [weak self] in
            let updates = await monitor.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard let self,
                      self.sessionID == sessionID,
                      self.isRunning else { return }
                self.snapshot = update
            }
        }
    }

    private func enqueueStart(sessionID: UUID) {
        let previous = controlTask
        let monitor = monitor
        controlTask = Task { [weak self] in
            await previous?.value
            guard let self,
                  self.sessionID == sessionID,
                  self.isRunning else { return }
            await monitor.start()
            guard self.sessionID == sessionID, self.isRunning else { return }
            self.subscribe(sessionID: sessionID)
        }
    }

    private func enqueueStop() {
        let previous = controlTask
        let monitor = monitor
        controlTask = Task {
            await previous?.value
            await monitor.stop()
        }
    }

    deinit {
        updateTask?.cancel()
        controlTask?.cancel()
        let monitor = monitor
        Task {
            await monitor.stop()
        }
    }
}
