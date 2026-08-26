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
    ///
    /// The clip picker is the one popup the user deliberately opened, so it
    /// outranks anything that announces itself: a copy landing mid-selection
    /// used to replace the list with a notice and lose their place.
    static func shouldShowCopyHUD(
        popupEnabled: Bool,
        isExpanded: Bool,
        hudContent: HudContent?
    ) -> Bool {
        guard popupEnabled, !isExpanded else { return false }
        if case .clipPicker = hudContent { return false }
        return true
    }

    func showCopyHUD(_ clip: ClipboardService.Clip) {
        guard Self.shouldShowCopyHUD(
            popupEnabled: services.hudPreferences.copyPopup,
            isExpanded: isExpanded,
            hudContent: hudContent
        ) else { return }
        pendingHudDismiss?.cancel()
        withAnimation(transitionAnimation) { hudContent = .clip(clip) }
        armHudDismiss()
        pasteMonitor.start()
    }

    func dismissHUD() {
        pasteMonitor.stop()
        pickerKeyMonitor.stop()
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
        // Same reason as `toggle()`: the picker may be the HUD being expanded
        // away from, and its key monitor has to go with it.
        pickerKeyMonitor.stop()
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
        pick(clip)
        dismissHUD()
    }

    /// The one path every clip picker goes through: put the clip back on the
    /// pasteboard, and — when the user wants it and Accessibility allows —
    /// finish the job by typing the ⌘V into whatever they were working in.
    ///
    /// Without the grant the clip is still copied; the hint says so once rather
    /// than leaving the pick looking like it did nothing.
    func pick(
        _ clip: ClipboardService.Clip,
        pasteAfter delay: TimeInterval = PasteSynthesizer.defaultDelay
    ) {
        let token = services.clipboard.copy(clip)
        guard services.hudPreferences.autoPaste else { return }
        let clipboard = services.clipboard
        // Only paste if this clip is still what the pasteboard is offering.
        // Something else can write in the beat between the two — Universal
        // Clipboard, another manager — and pasting anyway would put content
        // in the document that the user never picked.
        let paste = pasteSynthesizer.pasteToFrontmostApp(after: delay) {
            clipboard.changeCount == token
        }
        if paste {
            pasteHint = nil
        } else if pasteHint == nil {
            pasteHint = "Copied. Grant Accessibility to paste automatically."
        }
    }

    /// Puts a clip back on the pasteboard and stops there.
    ///
    /// The dashboard's clipboard tiles use this rather than `pick`. Reaching
    /// them means clicking the panel, which makes the notch the key window
    /// without it having borrowed focus from anywhere — so there is nowhere to
    /// hand the keyboard back to, and the synthesized ⌘V was delivered to the
    /// overlay itself. Copying and saying so is honest; pasting into thin air
    /// is not.
    func copyWithoutPaste(_ clip: ClipboardService.Clip) {
        services.clipboard.copy(clip)
    }

    // MARK: - Clipboard picker

    /// What a key press means while the picker is up.
    enum PickerAction: Equatable {
        case select(Int) // 1-based, matching the badge on each row
        case dismiss
    }

    /// Pure so the key mapping is testable without an event or a window.
    ///
    /// Digits pick; Escape, Return and Space close. Everything else is ignored
    /// rather than swallowed, since the picker sits over whatever the user was
    /// doing.
    ///
    /// Modifiers are the reason this takes them. A bare digit picks, but ⌘1 is
    /// switch-to-first-tab in every browser and something of its own in most
    /// other apps — and the picker has no auto-dismiss, sits on every Space,
    /// and is easy not to notice. Reading ⌘1 as "pick the first clip" meant an
    /// unnoticed picker turned a tab switch into a paste of whatever was
    /// copied first, and swallowed the shortcut on the way.
    ///
    /// Shift is allowed through: on layouts where the number row is shifted,
    /// Shift is how a digit is typed at all. `characters` rather than
    /// `charactersIgnoringModifiers` keeps ⇧1 on a US layout as "!", which
    /// selects nothing.
    ///
    /// Return and Space dismiss rather than select. With Full Keyboard Access
    /// on they activate whichever row SwiftUI focused first — the top one — so
    /// leaving them unhandled meant a silent pick of the newest clip.
    static func pickerAction(
        forKeyCode keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags = []
    ) -> PickerAction? {
        switch keyCode {
        case 53, 36, 76, 49: return .dismiss // Escape, Return, keypad Enter, Space
        default: break
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        guard let digit = characters.flatMap(Int.init), (1 ... 9).contains(digit) else { return nil }
        return .select(digit)
    }

    /// The global shortcut is a toggle: pressing it again closes the picker
    /// rather than doing nothing, which is what the same key press means
    /// everywhere else in macOS.
    func toggleClipPicker() {
        if case .clipPicker = hudContent {
            dismissHUD()
        } else {
            showClipPicker()
        }
    }

    /// The two presentation flags the clip picker needs, set together.
    ///
    /// They are separately `@Published` and the window tier map reads both,
    /// with `isExpanded` outranking `hudContent`. Setting only `hudContent`
    /// showed nothing at all while the dashboard was open, and then dropped the
    /// picker out of the notch unasked the moment the dashboard collapsed.
    struct Presentation: Equatable {
        var isExpanded: Bool
        var hudContent: HudContent?
    }

    static let clipPickerPresentation = Presentation(isExpanded: false, hudContent: .clipPicker)

    func showClipPicker() {
        pendingHudDismiss?.cancel()
        pendingHudDismiss = nil
        pendingPeekPromotion?.cancel()
        pendingPeekPromotion = nil
        cancelPendingCollapse()
        pasteMonitor.stop()
        // The chord is global, so it has to work while the dashboard happens to
        // be open — and `isExpanded` outranks `hudContent` in the tier map. Set
        // both in one animation: leaving `isExpanded` true showed nothing at
        // all, and then dropped the picker out of the notch unasked the moment
        // something else collapsed the dashboard. Unpinning matters for the
        // same reason — a dashboard pinned open by the menu would otherwise
        // keep the hover-out collapse from ever running.
        isManuallyPinned = false
        // No auto-dismiss timer: unlike the copy popup, this one is waiting for
        // the user to choose something.
        // Order matters, and it is the opposite of how it reads. Both
        // properties publish in willSet, so the window controller sees each
        // assignment separately: setting `isExpanded` first published a state
        // with no HUD content and nothing expanded — the collapsed tier — and
        // the picker's own tier a moment later, so two window animations ran
        // against each other and the frame could settle on the smaller one
        // while the content stayed picker-sized. Raising `hudContent` first
        // leaves the intermediate state on the tier it is already showing, and
        // the picker arrives in a single step. Same reason as `expandFromHUD`
        // and `armPeekPromotion` below.
        withAnimation(transitionAnimation) {
            hudContent = Self.clipPickerPresentation.hudContent
            isExpanded = Self.clipPickerPresentation.isExpanded
        }
        pickerKeyMonitor.start()
    }

    /// Act on a key press while the picker is showing.
    func handlePickerKey(
        code: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard case .clipPicker = hudContent else { return false }
        switch Self.pickerAction(forKeyCode: code, characters: characters, modifiers: modifiers) {
        case .dismiss:
            dismissHUD()
            return true
        case .select(let index):
            let clips = services.clipboard.clips
            guard index <= clips.count else { return true }
            pickAndDismiss(clips[index - 1])
            return true
        case nil:
            return false
        }
    }

    /// Choosing from the picker: close first, then paste. Dismissing hands the
    /// keyboard back to the app the user was working in, and the longer delay
    /// gives that hand-off time to land before the ⌘V is typed.
    func pickAndDismiss(_ clip: ClipboardService.Clip) {
        dismissHUD()
        pick(clip, pasteAfter: PasteSynthesizer.focusHandoffDelay)
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
        // A copy popup is more actionable than a charge notice, and the clip
        // picker is something the user is actively reading; don't replace either.
        if case .clip = hudContent { return }
        if case .clipPicker = hudContent { return }
        pendingHudDismiss?.cancel()
        withAnimation(transitionAnimation) { hudContent = .charging }
        let work = DispatchWorkItem { [weak self] in self?.dismissHUD() }
        pendingHudDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
