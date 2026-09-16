import Foundation

/// Owns display demand independently from rendering and from the sampler's lifecycle.
@MainActor
final class NetworkTrafficVisibility {
    private let start: @MainActor () -> Void
    private let stop: @MainActor () -> Void
    private var visibleContentIDs: Set<UUID> = []
    private var isSelected = false
    private var isShutdown = false
    private(set) var isRunning = false

    init(start: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void) {
        self.start = start
        self.stop = stop
    }

    func setContentVisible(_ visible: Bool, id: UUID) {
        if visible {
            visibleContentIDs.insert(id)
        } else {
            visibleContentIDs.remove(id)
        }
        reconcile()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        reconcile()
    }

    func shutdown() {
        isShutdown = true
        reconcile()
    }

    private func reconcile() {
        let shouldRun = isSelected && !visibleContentIDs.isEmpty && !isShutdown
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun {
            start()
        } else {
            stop()
        }
    }
}

public extension AppPresentationModel {
    internal func updateNetworkVisibility() {
        networkVisibility.setSelected(edition == .direct && tier == .detail && selectedCapability == .network)
    }

    func setNetworkContentVisible(_ visible: Bool, id: UUID) {
        networkVisibility.setContentVisible(visible, id: id)
    }

    func stopNetworkMonitoring() {
        networkVisibility.shutdown()
    }
}
