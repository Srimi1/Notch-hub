import Foundation
import NotchHubNetwork
import Observation

/// Display choices belong to this app's defaults domain; traffic never persists.
@MainActor
@Observable
final class NetworkModulePreferences {
    static let unitKey = "network.trafficUnit"

    var unit: NetworkTrafficUnit {
        didSet { defaults.set(unit.rawValue, forKey: Self.unitKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = defaults.string(forKey: Self.unitKey)
            .flatMap(NetworkTrafficUnit.init(rawValue:)) ?? .megabitsPerSecond
    }
}
