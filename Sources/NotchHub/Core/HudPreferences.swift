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
        static let autoPaste = "hud.autoPaste"
    }

    var copyPopup: Bool {
        didSet { defaults.set(copyPopup, forKey: Key.copyPopup) }
    }

    var chargingPopup: Bool {
        didSet { defaults.set(chargingPopup, forKey: Key.chargingPopup) }
    }

    /// Whether picking a clip also types the ⌘V into the frontmost app. Falls
    /// back to copy-only when Accessibility is missing, so leaving this on
    /// costs nothing.
    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyPopup = defaults.object(forKey: Key.copyPopup) as? Bool ?? true
        chargingPopup = defaults.object(forKey: Key.chargingPopup) as? Bool ?? true
        autoPaste = defaults.object(forKey: Key.autoPaste) as? Bool ?? true
    }
}
