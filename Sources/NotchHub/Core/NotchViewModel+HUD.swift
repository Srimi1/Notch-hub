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
    ///
    /// `isExpanded` and `hudContent` are independently `@Published`, and
    /// `NotchWindowController` derives its window tier from both together. If
    /// `hudContent` clears before `isExpanded` flips, the window observes a
    /// transient (not expanded, no hud) state and briefly collapses to the
    /// bare notch before re-expanding — a visible double-hop that can leave
    /// the content geometry desynced. Flipping `isExpanded` first makes the
    /// tier map short-circuit straight to `.expanded`, so clearing
    /// `hudContent` afterward is a no-op tier-wise. Same fix as
    /// `armPeekPromotion` below.
    func expandFromHUD() {
        pendingHudDismiss?.cancel()
        pendingHudDismiss = nil
        if preferences.isVisible(.clipboard) { select(.clipboard) }
        beginInteractiveIfNeeded()
        // Deliberately NOT pinned. Clicking the popup means "show me the
        // clipboard", not "keep this open forever" — pinning it here left the
        // dashboard stuck open, since the hover-out collapse refuses to run
        // while `isManuallyPinned` is set. Only the menu's Toggle Notch pins;
        // this expands like a hover and collapses when the pointer leaves.
        withAnimation(transitionAnimation) {
            isExpanded = true
            hudContent = nil
        }
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

    /// See the ordering note on `expandFromHUD` — `isExpanded` must flip
    /// before `hudContent` clears, in the same animation, or the window
    /// collapses and re-expands instead of growing straight from peek to
    /// dashboard size.
    func armPeekPromotion() {
        pendingPeekPromotion?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .peek = self.hudContent else { return }
            self.pendingPeekPromotion = nil
            self.presentCurrentActivity()
            withAnimation(self.transitionAnimation) {
                self.isExpanded = true
                self.hudContent = nil
            }
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
