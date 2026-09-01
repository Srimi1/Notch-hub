import Foundation
import Observation

/// How long a copy confirmation remains visible when the pointer is not over it.
/// The raw value is persisted, while the duration and user-facing label stay in
/// one typed table so Settings and the HUD cannot drift apart.
enum CopyPopupDurationPreset: String, CaseIterable, Identifiable {
    case brief
    case standard
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: "Brief"
        case .standard: "Standard"
        case .long: "Long"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .brief: 1.5
        case .standard: 2.5
        case .long: 4.0
        }
    }
}

/// Switches for the transient notch popups. Separate from `ModulePreferences`
/// because these are moments, not modules — hiding the Clipboard module already
/// stops pasteboard reading entirely; this only decides whether a copy is
/// announced.
@MainActor
@Observable
final class HudPreferences {
    private enum Key {
        static let copyPopup = "hud.copyPopup"
        static let copyPopupDuration = "hud.copyPopupDuration"
        static let chargingPopup = "hud.chargingPopup"
        static let autoPaste = "hud.autoPaste"
    }

    var copyPopup: Bool {
        didSet { defaults.set(copyPopup, forKey: Key.copyPopup) }
    }

    var copyPopupDuration: CopyPopupDurationPreset {
        didSet { defaults.set(copyPopupDuration.rawValue, forKey: Key.copyPopupDuration) }
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
        copyPopupDuration = defaults.string(forKey: Key.copyPopupDuration)
            .flatMap(CopyPopupDurationPreset.init(rawValue:)) ?? .brief
        chargingPopup = defaults.object(forKey: Key.chargingPopup) as? Bool ?? true
        autoPaste = defaults.object(forKey: Key.autoPaste) as? Bool ?? true
    }
}
