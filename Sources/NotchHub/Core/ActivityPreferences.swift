import Foundation
import Observation

@MainActor
@Observable
final class ActivityPreferences {
    private enum Key {
        static let enabledKinds = "nextUp.enabledKinds"
        static let calendarLeadMinutes = "nextUp.calendarLeadMinutes"
        static let reminderLeadMinutes = "nextUp.reminderLeadMinutes"
        static let batteryWarningPercent = "nextUp.batteryWarningPercent"
        static let urgentOverridesMedia = "nextUp.urgentOverridesMedia"
    }

    var enabledKinds: Set<ActivityKind> {
        didSet { persistEnabledKinds(); onChange?() }
    }

    var calendarLeadMinutes: Int {
        didSet { persist(calendarLeadMinutes, key: Key.calendarLeadMinutes); onChange?() }
    }

    var reminderLeadMinutes: Int {
        didSet { persist(reminderLeadMinutes, key: Key.reminderLeadMinutes); onChange?() }
    }

    var batteryWarningPercent: Int {
        didSet { persist(batteryWarningPercent, key: Key.batteryWarningPercent); onChange?() }
    }

    var urgentOverridesMedia: Bool {
        didSet { defaults.set(urgentOverridesMedia, forKey: Key.urgentOverridesMedia); onChange?() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let stored = defaults.array(forKey: Key.enabledKinds) as? [String] {
            let restored = Set(stored.compactMap(ActivityKind.init(rawValue:)))
            enabledKinds = stored.isEmpty || !restored.isEmpty ? restored : Set(ActivityKind.allCases)
        } else {
            enabledKinds = Set(ActivityKind.allCases)
        }

        calendarLeadMinutes = Self.bounded(
            defaults.object(forKey: Key.calendarLeadMinutes) as? Int ?? 15,
            range: 5 ... 60
        )
        reminderLeadMinutes = Self.bounded(
            defaults.object(forKey: Key.reminderLeadMinutes) as? Int ?? 30,
            range: 5 ... 240
        )
        batteryWarningPercent = Self.bounded(
            defaults.object(forKey: Key.batteryWarningPercent) as? Int ?? 20,
            range: 5 ... 50
        )
        urgentOverridesMedia = defaults.object(forKey: Key.urgentOverridesMedia) as? Bool ?? true
    }

    func isEnabled(_ kind: ActivityKind) -> Bool {
        enabledKinds.contains(kind)
    }

    func setEnabled(_ kind: ActivityKind, enabled: Bool) {
        if enabled {
            enabledKinds.insert(kind)
        } else {
            enabledKinds.remove(kind)
        }
    }

    func setCalendarLeadMinutes(_ value: Int) {
        calendarLeadMinutes = Self.bounded(value, range: 5 ... 60)
    }

    func setReminderLeadMinutes(_ value: Int) {
        reminderLeadMinutes = Self.bounded(value, range: 5 ... 240)
    }

    func setBatteryWarningPercent(_ value: Int) {
        batteryWarningPercent = Self.bounded(value, range: 5 ... 50)
    }

    private func persistEnabledKinds() {
        let values = enabledKinds.map(\.rawValue).sorted()
        defaults.set(values, forKey: Key.enabledKinds)
    }

    private func persist(_ value: Int, key: String) {
        defaults.set(value, forKey: key)
    }

    private static func bounded(_ value: Int, range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
