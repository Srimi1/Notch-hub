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
}

@MainActor
final class NotchViewModel: ObservableObject {

    @Published private(set) var isExpanded = false
    /// The middle presentation tier: bigger than the collapsed pill, far
    /// smaller than the dashboard. `isExpanded` always wins over it.
    @Published private(set) var hudContent: HudContent?
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

    /// How long a copy popup lingers before sliding away on its own.
    private let hudDismissDelay: TimeInterval = 4.0
    private var pendingHudDismiss: DispatchWorkItem?
    /// Sustained hover on the peek promotes it to the full dashboard.
    private let peekPromotionDelay: TimeInterval = 0.6
    private var pendingPeekPromotion: DispatchWorkItem?
    /// Dismisses the popup the instant its content is pasted — but only when
    /// Accessibility was already granted for the Focus toggle. Never prompts.
    private let pasteMonitor = PasteEventMonitor()

    /// Tracks live hover so we know whether to collapse once a pin is released.
    private var isHovering = false
    /// The menu-bar "Toggle Notch" action is intentional, not hover-driven. Keep
    /// that expanded state pinned until the user toggles it again.
    private var isManuallyPinned = false
    private var transitionAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.35, dampingFraction: 0.82)
    }

    private var cancellables = Set<AnyCancellable>()

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
        observeCharging()
    }

    /// Announce the cable. `isCharging` flips instantly thanks to the battery
    /// service's IOKit callback, so the moment lands while the connector is
    /// still in hand — the Dynamic Island beat, not a delayed echo of it.
    private func observeCharging() {
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
    private var canPeek: Bool {
        !services.clipboard.clips.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Clicking a peek card puts that clip back on the pasteboard.
    func restoreFromPeek(_ clip: ClipboardService.Clip) {
        services.clipboard.copy(clip)
        dismissHUD()
    }

    private func armPeekPromotion() {
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

    private func armHudDismiss() {
        pendingHudDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissHUD() }
        pendingHudDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudDismissDelay, execute: work)
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

    func toggle() {
        pendingCollapse?.cancel()
        dismissHUD()
        beginInteractiveIfNeeded()
        if !isExpanded { presentCurrentActivity() }
        isManuallyPinned = !isExpanded
        withAnimation(transitionAnimation) { isExpanded.toggle() }
    }

    func collapse() {
        pendingCollapse?.cancel()
        dismissHUD()
        isManuallyPinned = false
        presentedActivityID = nil
        actionError = nil
        withAnimation(transitionAnimation) { isExpanded = false }
    }

    private func beginInteractiveIfNeeded() {
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

    private func presentCurrentActivity() {
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
