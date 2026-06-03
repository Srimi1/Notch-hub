import Combine
import SwiftUI

/// Reactive state for the notch overlay. `isExpanded` drives both the SwiftUI
/// content (via this `ObservableObject`) and the window-frame animation (the
/// window controller subscribes to the published value).
final class NotchViewModel: ObservableObject {

    @Published private(set) var isExpanded = false
    @Published var activeModule: FeatureModule = .dashboard

    /// Persisted dashboard layout (which modules are shown, last active module).
    /// Shared with `AppDelegate`'s status-bar menu so menu toggles and the
    /// dashboard stay in sync.
    let preferences: ModulePreferences

    /// Live data layer. Ambient services tick from launch; interactive
    /// (permission-gated) services start the first time the notch expands so a
    /// new user isn't hit with a wall of prompts before seeing the UI.
    let services = ServiceHub()
    private var startedInteractive = false

    /// When true, the collapsed pill grows symmetric "wings" beside the notch
    /// to surface a live activity (now playing / focus / low battery) —
    /// the collapsed equivalent of MacNotch's Live Activities strip. Width is
    /// added on both sides so the black notch body stays aligned with the
    /// physical camera housing.
    @Published private(set) var showCollapsedWings = false
    let collapsedWingWidth: CGFloat = 92

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
    /// While a RAM clean is in flight (and briefly after, to show the result),
    /// the notch stays expanded even if the mouse leaves — otherwise the panel
    /// collapses the moment you move to the auth dialog and you never see the
    /// "Freed …" result.
    private var cleanPinned = false

    private let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    private var cancellables = Set<AnyCancellable>()

    init(preferences: ModulePreferences) {
        self.preferences = preferences
        // Restore the last-viewed module, but only if it's still visible —
        // otherwise fall back to the first visible module (or dashboard).
        let restored = preferences.lastActiveModule
        activeModule = preferences.isVisible(restored)
            ? restored
            : (preferences.visibleModules.first ?? .dashboard)

        services.startAmbient()
        observeLiveActivity()
        observeCleaner()
        forwardPreferenceChanges()
    }

    /// Re-emit preference changes (e.g. a module toggled from the status menu)
    /// so any view observing this view model refreshes the toggle band live.
    private func forwardPreferenceChanges() {
        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Pin the notch open while the RAM cleaner is busy / showing its result.
    private func observeCleaner() {
        services.memoryCleaner.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                self.cleanPinned = active
                if active {
                    self.pendingCollapse?.cancel()
                    if !self.isExpanded { withAnimation(self.spring) { self.isExpanded = true } }
                } else if !self.isHovering {
                    // Result has been shown; collapse now (unless still hovering).
                    withAnimation(self.spring) { self.isExpanded = false }
                }
            }
            .store(in: &cancellables)
    }

    /// Drive `showCollapsedWings` from any live activity worth surfacing.
    private func observeLiveActivity() {
        let media = services.media.$nowPlaying.map { $0 != nil }
        let focus = services.focus.$isOn
        let lowBattery = services.battery.$level
            .combineLatest(services.battery.$hasBattery, services.battery.$isCharging)
            .map { level, has, charging in has && !charging && level <= 0.20 }

        media.combineLatest(focus, lowBattery)
            .map { mediaActive, focusOn, lowBattery in
                mediaActive || focusOn || lowBattery
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                withAnimation(self.spring) { self.showCollapsedWings = active }
            }
            .store(in: &cancellables)
    }

    func setHover(_ hovering: Bool) {
        isHovering = hovering
        pendingCollapse?.cancel()

        if hovering {
            guard !isExpanded else { return }
            beginInteractiveIfNeeded()
            withAnimation(spring) { isExpanded = true }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.cleanPinned else { return } // stay open through a clean
                withAnimation(self.spring) { self.isExpanded = false }
            }
            pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
        }
    }

    func toggle() {
        pendingCollapse?.cancel()
        beginInteractiveIfNeeded()
        withAnimation(spring) { isExpanded.toggle() }
    }

    private func beginInteractiveIfNeeded() {
        guard !startedInteractive else { return }
        startedInteractive = true
        services.startInteractive()
    }

    func select(_ module: FeatureModule) {
        activeModule = module
        preferences.lastActiveModule = module
    }
}
