import Combine
import Foundation
import SwiftUI

/// Single owner of every live data service. Injected into the SwiftUI
/// environment so any module view can read live state, and given a coarse
/// lifecycle so polling only runs while the app is active.
///
/// This is the service layer NotchHub previously lacked — the reason every
/// module rendered hardcoded placeholder data. Mirrors how MacNotch fans a set
/// of `ObservableObject` singletons (`MediaService`, `BluetoothService`,
/// `SystemMonitorService`, …) out to its `*ModuleView`s.
final class ServiceHub: ObservableObject {

    let time = TimeService()
    let system = SystemMonitorService()
    let purgePrivilege = PurgePrivilege()
    let memoryCleaner: MemoryCleanerService
    let battery = BatteryService()
    let media = MediaService()
    let calendar = CalendarService()
    let clipboard = ClipboardService()
    let focus = FocusService()
    let aiCoding = AICodingService()

    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        memoryCleaner = MemoryCleanerService(privilege: purgePrivilege)

        // Re-publish whenever any child service changes, so container views
        // that switch on cross-service state (the live strip, the collapsed
        // wing selector) stay reactive without observing each child directly.
        let forward: () -> Void = { [weak self] in self?.objectWillChange.send() }
        let publishers: [ObservableObjectPublisher] = [
            time.objectWillChange, system.objectWillChange, battery.objectWillChange,
            media.objectWillChange, calendar.objectWillChange,
            clipboard.objectWillChange, focus.objectWillChange, aiCoding.objectWillChange,
            memoryCleaner.objectWillChange, purgePrivilege.objectWillChange
        ]
        for publisher in publishers {
            publisher.sink { forward() }.store(in: &cancellables)
        }
    }

    /// Lightweight services tick immediately; permission-gated ones
    /// (calendar, AppleScript media) start on first expand so a brand-new user
    /// isn't hit with a wall of prompts before seeing the UI.
    func startAmbient() {
        guard !started else { return }
        started = true
        time.start()
        system.start()
        battery.start()
        clipboard.start()
        focus.start()
        aiCoding.start()
        purgePrivilege.refresh()
    }

    func startInteractive() {
        media.start()
        calendar.start()
    }

    func stopInteractive() {
        media.stop()
    }
}
