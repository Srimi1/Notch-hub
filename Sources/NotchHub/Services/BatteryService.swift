import Combine
import Foundation
import IOKit.ps

/// Live battery state via IOKit power-source APIs (public, no permissions).
/// Reports charge level, charging/charged state, and time-to-full/empty.
/// On desktop Macs with no battery, `hasBattery` is false.
///
/// Main-actor isolated: every reader is a SwiftUI view or `ServiceHub`, and both
/// IOKit callbacks below are delivered on the main run loop.
@MainActor
final class BatteryService: ObservableObject {

    @Published private(set) var hasBattery = false
    /// 0…1 charge fraction.
    @Published private(set) var level: Double = 0
    @Published private(set) var isCharging = false
    @Published private(set) var isCharged = false
    /// Minutes to full (charging) or empty (discharging); nil if "calculating".
    @Published private(set) var minutesRemaining: Int?
    /// macOS Low Power Mode. Reported so the UI can show the same yellow the
    /// system does, rather than inventing its own signal.
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var timer: Timer?
    private var powerSourceSource: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observePowerSourceChanges()
        observeLowPowerMode()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceSource, .commonModes)
            self.powerSourceSource = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    /// Re-sample the instant the cable goes in or out.
    ///
    /// The 30-second tick is fine for a slowly draining percentage but far too
    /// slow for plugging in: the user would watch the glyph stay red for up to
    /// half a minute after connecting power. IOKit will tell us immediately.
    private func observePowerSourceChanges() {
        guard powerSourceSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // Delivered on the run loop this source was added to — the main one.
            MainActor.assumeIsolated {
                Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue().sample()
            }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceSource = source
    }

    /// `NSProcessInfoPowerStateDidChange` is posted off the main thread, so the
    /// published change has to be hopped back before SwiftUI sees it.
    private func observeLowPowerMode() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    // No `deinit` teardown: a main-actor-isolated deinit cannot touch this
    // state under Swift 6, and the hub owns this service for the whole process
    // lifetime. `stop()` is the real teardown path.

    var percent: Int { Int((level * 100).rounded()) }

    /// SF Symbol that matches the current charge/charging state.
    var symbol: String {
        if isCharging || isCharged { return "battery.100.bolt" }
        switch percent {
        case 0 ..< 13: return "battery.0"
        case 13 ..< 38: return "battery.25"
        case 38 ..< 63: return "battery.50"
        case 63 ..< 88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func sample() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            clearBatteryState()
            return
        }

        hasBattery = true

        if let current = desc[kIOPSCurrentCapacityKey] as? Int,
           let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
            level = min(Double(current) / Double(max), 1)
        }

        let state = desc[kIOPSPowerSourceStateKey] as? String
        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        isCharged = (desc[kIOPSIsChargedKey] as? Bool) ?? false
        _ = state

        // -1 means "still calculating"; surface nil so the UI can say so.
        let key = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        if let minutes = desc[key] as? Int, minutes >= 0 {
            minutesRemaining = minutes
        } else {
            minutesRemaining = nil
        }
    }

    private func clearBatteryState() {
        hasBattery = false
        level = 0
        isCharging = false
        isCharged = false
        minutesRemaining = nil
    }
}
