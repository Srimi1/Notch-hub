import AppKit
import Combine
import SwiftUI

/// Reactive state for the notch overlay. `isExpanded` drives both the SwiftUI
/// content (via this `ObservableObject`) and the window-frame animation (the
/// window controller subscribes to the published value).
@MainActor
final class NotchViewModel: ObservableObject {

    @Published private(set) var isExpanded = false
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

    init(preferences: ModulePreferences) {
        self.preferences = preferences
        // The hub needs the same preferences object so hiding a module really
        // stops the service behind it, rather than only hiding its tab.
        self.services = ServiceHub(modulePreferences: preferences)
        // Restore the last-viewed module, but only if it's still visible —
        // otherwise fall back to the first visible module (or dashboard).
        let restored = preferences.lastActiveModule
        activeModule = preferences.isVisible(restored)
            ? restored
            : (preferences.visibleModules.first ?? .dashboard)

        observeLiveActivity()
        forwardPreferenceChanges()
        services.startAmbient()
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

        if hovering {
            guard !isExpanded else { return }
            beginInteractiveIfNeeded()
            presentCurrentActivity()
            withAnimation(transitionAnimation) { isExpanded = true }
        } else {
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
        beginInteractiveIfNeeded()
        if !isExpanded { presentCurrentActivity() }
        isManuallyPinned = !isExpanded
        withAnimation(transitionAnimation) { isExpanded.toggle() }
    }

    func collapse() {
        pendingCollapse?.cancel()
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
