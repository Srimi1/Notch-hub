import Foundation
import Observation

/// Switches for the transient notch popups. Separate from `ModulePreferences`
/// because these are moments, not modules — hiding the Clipboard module already
/// stops pasteboard reading entirely; this only decides whether a copy is
/// announced.
@MainActor
@Observable
final class HudPreferences {
    private enum Key {
        static let copyPopup = "hud.copyPopup"
        static let chargingPopup = "hud.chargingPopup"
    }

    var copyPopup: Bool {
        didSet { defaults.set(copyPopup, forKey: Key.copyPopup) }
    }

    var chargingPopup: Bool {
        didSet { defaults.set(chargingPopup, forKey: Key.chargingPopup) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyPopup = defaults.object(forKey: Key.copyPopup) as? Bool ?? true
        chargingPopup = defaults.object(forKey: Key.chargingPopup) as? Bool ?? true
    }
}
