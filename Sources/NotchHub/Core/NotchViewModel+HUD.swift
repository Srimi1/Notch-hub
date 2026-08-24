import AppKit
import Combine
import SwiftUI

/// The transient popup tier — copy popup, hover peek, and the charge moment.
/// Split from the main class body: presentation state lives there, the
/// behavior lives here.
extension NotchViewModel {

    // MARK: - HUD tier

    /// Whether a fresh copy should raise the popup right now. Static so the
    /// rule is testable without building the service graph.
    static func shouldShowCopyHUD(popupEnabled: Bool, isExpanded: Bool) -> Bool {
        popupEnabled && !isExpanded
    }

    func showCopyHUD(_ clip: ClipboardService.Clip) {
        guard Self.shouldShowCopyHUD(
            popupEnabled: services.hudPreferences.copyPopup,
            isExpanded: isExpanded
        ) else { return }
        pendingHudDismiss?.cancel()
        withAnimation(transitionAnimation) { hudContent = .clip(clip) }
        armHudDismiss()
        pasteMonitor.start()
    }

    func dismissHUD() {
        pasteMonitor.stop()
        pendingHudDismiss?.cancel()
        pendingHudDismiss = nil
        pendingPeekPromotion?.cancel()
        pendingPeekPromotion = nil
        guard hudContent != nil else { return }
        withAnimation(transitionAnimation) { hudContent = nil }
    }

    /// Hovering the popup pauses the countdown so it can be read or dragged
    /// from; leaving re-arms it.
    func setHudHover(_ hovering: Bool) {
        guard hudContent != nil else { return }
        if hovering {
            pendingHudDismiss?.cancel()
            pendingHudDismiss = nil
        } else {
            armHudDismiss()
        }
    }

    /// Clicking the popup opens the full dashboard on the Clipboard module.
    func expandFromHUD() {
        pendingHudDismiss?.cancel()
        pendingHudDismiss = nil
        hudContent = nil
        if preferences.isVisible(.clipboard) { select(.clipboard) }
        beginInteractiveIfNeeded()
        isManuallyPinned = true
        withAnimation(transitionAnimation) { isExpanded = true }
    }

    /// A peek needs something to show, and under Reduce Motion the two-stage
    /// reveal is replaced by the old direct expansion.
    var canPeek: Bool {
        !services.clipboard.clips.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Clicking a peek card puts that clip back on the pasteboard.
    func restoreFromPeek(_ clip: ClipboardService.Clip) {
        services.clipboard.copy(clip)
        dismissHUD()
    }

    func armPeekPromotion() {
        pendingPeekPromotion?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .peek = self.hudContent else { return }
            self.pendingPeekPromotion = nil
            self.hudContent = nil
            self.presentCurrentActivity()
            withAnimation(self.transitionAnimation) { self.isExpanded = true }
        }
        pendingPeekPromotion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekPromotionDelay, execute: work)
    }

    func armHudDismiss() {
        pendingHudDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissHUD() }
        pendingHudDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudDismissDelay, execute: work)
    }

    /// Announce the cable. `isCharging` flips instantly thanks to the battery
    /// service's IOKit callback, so the moment lands while the connector is
    /// still in hand — the Dynamic Island beat, not a delayed echo of it.
    func observeCharging() {
        services.battery.$isCharging
            .removeDuplicates()
            .dropFirst() // launch state is not an event
            .receive(on: RunLoop.main)
            .sink { [weak self] charging in
                guard let self, charging else { return }
                self.showChargingHUD()
            }
            .store(in: &cancellables)
    }

    func showChargingHUD() {
        guard services.hudPreferences.chargingPopup, !isExpanded else { return }
        // A copy popup is more actionable than a charge notice; don't replace it.
        if case .clip = hudContent { return }
        pendingHudDismiss?.cancel()
        withAnimation(transitionAnimation) { hudContent = .charging }
        let work = DispatchWorkItem { [weak self] in self?.dismissHUD() }
        pendingHudDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
