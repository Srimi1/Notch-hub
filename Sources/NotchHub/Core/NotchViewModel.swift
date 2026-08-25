import AppKit
import Combine
import SwiftUI

/// Reactive state for the notch overlay. `isExpanded` drives both the SwiftUI
/// content (via this `ObservableObject`) and the window-frame animation (the
/// window controller subscribes to the published value).
/// What the transient HUD tier is showing, when it is showing anything.
enum HudContent: Equatable {
    /// The copy popup: something new just landed on the pasteboard.
    case clip(ClipboardService.Clip)
    /// The hover peek: the last few clips, shown before the full dashboard.
    case peek
    /// Power just connected — the charge moment.
    case charging
    /// The clipboard picker, opened by the global shortcut: the full history,
    /// keyboard-selectable, over whatever the user is working in.
    case clipPicker
}

@MainActor
final class NotchViewModel: ObservableObject {

    // Neither gets a `private(set)`: Swift's `private` is file-scoped, and the
    // setters are used from `NotchViewModel+HUD.swift`. Plain `var` already
    // limits external writes to this module (SwiftUI views are read-only via
    // `@ObservedObject`), so an explicit `internal(set)` here would be inert.
    @Published var isExpanded = false
    /// The middle presentation tier: bigger than the collapsed pill, far
    /// smaller than the dashboard. `isExpanded` always wins over it.
    @Published var hudContent: HudContent?
    @Published var activeModule: FeatureModule = .dashboard
    @Published private(set) var presentedActivityID: String?
    @Published private(set) var actionError: String?

    /// Persisted dashboard layout (which modules are shown, last active module).
    /// Shared with `AppDelegate`'s status-bar menu so menu toggles and the
    /// dashboard stay in sync.
    let preferences: ModulePreferences

    /// Live data layer. Ambient services tick from launch; interactive
    /// (permission-gated) services start the first time the notch expands so a
    /// new user isn't hit with a wall of prompts before seeing the UI.
    let services: ServiceHub
    private var startedInteractive = false

    /// When true, the collapsed pill grows symmetric "wings" beside the notch
    /// to surface a live activity (now playing / focus / low battery) —
    /// the collapsed equivalent of MacNotch's Live Activities strip. Width is
    /// added on both sides so the black notch body stays aligned with the
    /// physical camera housing.
    @Published private(set) var showCollapsedWings = false
    let collapsedWingWidth: CGFloat = 112

    /// Physical notch size on the active screen, published by the window
    /// controller. The expanded dashboard uses the width to leave a gap in the
    /// middle of its toggle row so buttons never hide behind the camera.
    @Published var notchSize: CGSize = CGSize(width: 200, height: 32)

    /// Small grace period before collapsing, so brushing past the edge of the
    /// expanded panel doesn't cause it to flicker shut.
    private let collapseDelay: TimeInterval = 0.15
    private var pendingCollapse: DispatchWorkItem?

    // HUD-tier state. Internal (not private) because the behavior lives in
    // NotchViewModel+HUD.swift and `private` is file-scoped in Swift.
    /// How long a copy popup lingers before sliding away on its own.
    let hudDismissDelay: TimeInterval = 4.0
    var pendingHudDismiss: DispatchWorkItem?
    /// Sustained hover on the peek promotes it to the full dashboard.
    let peekPromotionDelay: TimeInterval = 0.6
    var pendingPeekPromotion: DispatchWorkItem?
    /// Dismisses the popup the instant its content is pasted — but only when
    /// Accessibility was already granted for the Focus toggle. Never prompts.
    let pasteMonitor = PasteEventMonitor()
    /// Types the ⌘V for the user after they pick a clip, where allowed.
    let pasteSynthesizer = PasteSynthesizer()
    /// Digit and Escape handling while the clipboard picker is up. Local, so it
    /// needs no permission and can swallow the keys it uses.
    let pickerKeyMonitor = LocalKeyMonitor()
    /// Explains, once per session, why picking a clip only copied it.
    @Published var pasteHint: String?

    /// Tracks live hover so we know whether to collapse once a pin is released.
    private var isHovering = false
    /// The menu-bar "Toggle Notch" action is intentional, not hover-driven. Keep
    /// that expanded state pinned until the user toggles it again.
    var isManuallyPinned = false
    var transitionAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.35, dampingFraction: 0.82)
    }

    var cancellables = Set<AnyCancellable>()

    /// The hub is injected rather than built here: `AppDelegate` owns it for the
    /// whole app lifetime, so Settings can reach the live services even on a
    /// launch where no display exists yet and no notch window was created.
    init(preferences: ModulePreferences, services: ServiceHub) {
        self.preferences = preferences
        self.services = services
        // Restore the last-viewed module, but only if it's still visible —
        // otherwise fall back to the first visible module (or dashboard).
        let restored = preferences.lastActiveModule
        activeModule = preferences.isVisible(restored)
            ? restored
            : (preferences.visibleModules.first ?? .dashboard)

        observeLiveActivity()
        forwardPreferenceChanges()

        services.clipboard.onCopy = { [weak self] clip in
            self?.showCopyHUD(clip)
        }
        pasteMonitor.onPaste = { [weak self] in
            self?.dismissHUD()
        }
        pickerKeyMonitor.onKeyDown = { [weak self] event in
            self?.handlePickerKey(
                code: event.keyCode,
                characters: event.charactersIgnoringModifiers
            ) ?? false
        }
        observeCharging()
    }

    /// Re-emit preference changes (e.g. a module toggled from the status menu)
    /// so any view observing this view model refreshes the toggle band live.
    private func forwardPreferenceChanges() {
        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Drive `showCollapsedWings` from the shared activity coordinator.
    private func observeLiveActivity() {
        services.activityCoordinator.activityDidChange
            .map { [weak self] in
                Self.shouldShowCollapsedWings(self?.services.activityCoordinator.currentActivity)
            }
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                withAnimation(self.transitionAnimation) { self.showCollapsedWings = active }
                if let presentedActivityID = self.presentedActivityID,
                   !self.services.activityCoordinator.queue.contains(where: { $0.id == presentedActivityID }) {
                    self.presentCurrentActivity()
                }
            }
            .store(in: &cancellables)
    }

    func setHover(_ hovering: Bool) {
        isHovering = hovering
        pendingCollapse?.cancel()

        // While the copy popup is up, the window IS the popup — hover pauses
        // its countdown instead of expanding, so it can be read and dragged from.
        if case .clip = hudContent, !isExpanded {
            setHudHover(hovering)
            return
        }

        if hovering {
            guard !isExpanded else { return }
            beginInteractiveIfNeeded()
            // Grazing the notch used to detonate the full 860pt dashboard.
            // Show the peek first; dwelling (or clicking) still opens it all.
            if hudContent == nil, canPeek {
                withAnimation(transitionAnimation) { hudContent = .peek }
                armPeekPromotion()
            } else if hudContent == nil {
                presentCurrentActivity()
                withAnimation(transitionAnimation) { isExpanded = true }
            }
        } else {
            if case .peek = hudContent {
                pendingPeekPromotion?.cancel()
                pendingPeekPromotion = nil
                withAnimation(transitionAnimation) { hudContent = nil }
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isManuallyPinned else { return }
                withAnimation(self.transitionAnimation) { self.isExpanded = false }
            }
            pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
        }
    }

    /// Drop a queued hover-out collapse.
    ///
    /// Anything that takes the window somewhere deliberate has to cancel it, or
    /// a stale work item fires up to `collapseDelay` later and flips
    /// `isExpanded` out from under the new state.
    func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    func toggle() {
        pendingCollapse?.cancel()
        beginInteractiveIfNeeded()
        let willExpand = !isExpanded
        if willExpand { presentCurrentActivity() }
        isManuallyPinned = willExpand
        // Stop the HUD's own timers without letting it animate hudContent to
        // nil on its own — see the ordering note on `expandFromHUD`. When
        // expanding, isExpanded has to flip in the SAME animation that clears
        // hudContent, or the window collapses and re-expands instead of
        // growing straight from whatever HUD tier was showing (⌘T pressed
        // while a popup or peek is up).
        pasteMonitor.stop()
        pendingHudDismiss?.cancel()
        pendingHudDismiss = nil
        pendingPeekPromotion?.cancel()
        pendingPeekPromotion = nil
        withAnimation(transitionAnimation) {
            isExpanded = willExpand
            hudContent = nil
        }
    }

    func collapse() {
        pendingCollapse?.cancel()
        dismissHUD()
        isManuallyPinned = false
        presentedActivityID = nil
        actionError = nil
        withAnimation(transitionAnimation) { isExpanded = false }
    }

    func beginInteractiveIfNeeded() {
        guard !startedInteractive else { return }
        startedInteractive = true
        services.startInteractive()
    }

    func select(_ module: FeatureModule) {
        presentedActivityID = nil
        actionError = nil
        activeModule = module
        preferences.lastActiveModule = module
    }

    var presentedActivity: ActivitySnapshot? {
        guard let presentedActivityID else { return nil }
        if let queued = services.activityCoordinator.queue.first(where: { $0.id == presentedActivityID }) {
            return queued
        }
        let current = services.activityCoordinator.currentActivity
        return Self.shouldPresentActivity(current) ? current : nil
    }

    func present(_ activity: ActivitySnapshot) {
        presentedActivityID = Self.shouldPresentActivity(activity) ? activity.id : nil
        actionError = nil
    }

    func dismissActivity() {
        presentedActivityID = nil
        actionError = nil
    }

    func selectVisibleModule(at index: Int) {
        guard preferences.visibleModules.indices.contains(index) else { return }
        select(preferences.visibleModules[index])
    }

    func performPrimaryActivityAction() {
        guard let action = presentedActivity?.actions.first else { return }
        perform(action)
    }

    func perform(_ action: ActivityAction) {
        actionError = nil
        switch action {
        case let .joinMeeting(url):
            guard let safeURL = SafeExternalURL.meetingURL(url) else {
                reportActionError("NotchHub blocked an unsafe meeting link.")
                return
            }
            open(safeURL, failureMessage: "The meeting link could not be opened.")
        case let .openLocation(location):
            guard let url = SafeExternalURL.mapsURL(for: location) else {
                reportActionError("That event location is invalid.")
                return
            }
            open(url, failureMessage: "Maps could not open that location.")
        case .openCalendar:
            openCalendar()
        case let .completeReminder(id):
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.services.reminders.complete(id: id) {
                    self.presentCurrentActivity()
                } else {
                    self.reportActionError(
                        self.services.reminders.lastError ?? "The reminder could not be completed."
                    )
                }
            }
        case .requestRemindersAccess:
            Task { @MainActor [weak self] in await self?.services.reminders.requestAccess() }
        case let .pauseTimer(id):
            services.timers.pause(id: id)
        case let .resumeTimer(id):
            services.timers.resume(id: id)
        case let .cancelTimer(id):
            services.timers.cancel(id: id)
        case let .dismissTimer(id):
            services.timers.dismiss(id: id)
        case .toggleMedia:
            services.media.playPause()
        case let .navigate(module):
            select(module)
        }
    }

    func presentCurrentActivity() {
        let current = services.activityCoordinator.currentActivity
        presentedActivityID = Self.shouldPresentActivity(current) ? current?.id : nil
        actionError = nil
    }

    static func shouldShowCollapsedWings(_ activity: ActivitySnapshot?) -> Bool {
        guard let activity else { return false }
        return activity.priority != .ambient
    }

    static func shouldPresentActivity(_ activity: ActivitySnapshot?) -> Bool {
        guard let activity else { return false }
        return activity.priority != .ambient
    }

    private func open(_ url: URL, failureMessage: String) {
        guard NSWorkspace.shared.open(url) else {
            reportActionError(failureMessage)
            return
        }
    }

    private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            reportActionError("Calendar is not available on this Mac.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            if let error {
                Task { @MainActor [weak self] in self?.reportActionError(error.localizedDescription) }
            }
        }
    }

    private func reportActionError(_ message: String) {
        actionError = message
        NSLog("NotchHub activity action: %@", message)
    }
}
