import Foundation

/// Keeps SwiftUI view lifetime separate from whether app state permits sampling.
/// A selection change can be reversed before SwiftUI rebuilds the view hierarchy,
/// so ineligibility stops the session without forgetting rows that remain mounted.
@MainActor
final class NetworkModulePresentation {
    private var visibleIDs: Set<UUID> = []
    private var isEligible = false
    private var isRunning = false

    func setVisible(_ visible: Bool, id: UUID, start: () -> Void, stop: () -> Void) {
        if visible {
            visibleIDs.insert(id)
        } else {
            visibleIDs.remove(id)
        }
        reconcile(start: start, stop: stop)
    }

    func setEligible(_ eligible: Bool, start: () -> Void, stop: () -> Void) {
        isEligible = eligible
        reconcile(start: start, stop: stop)
    }

    private func reconcile(start: () -> Void, stop: () -> Void) {
        let shouldRun = isEligible && !visibleIDs.isEmpty
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun {
            start()
        } else {
            stop()
        }
    }
}
