import Combine
import Foundation
import IOKit.ps

/// Live battery state via IOKit power-source APIs (public, no permissions).
/// Reports charge level, charging/charged state, and time-to-full/empty.
/// On desktop Macs with no battery, `hasBattery` is false.
final class BatteryService: ObservableObject {

    @Published private(set) var hasBattery = false
    /// 0…1 charge fraction.
    @Published private(set) var level: Double = 0
    @Published private(set) var isCharging = false
    @Published private(set) var isCharged = false
    /// Minutes to full (charging) or empty (discharging); nil if "calculating".
    @Published private(set) var minutesRemaining: Int?

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

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
