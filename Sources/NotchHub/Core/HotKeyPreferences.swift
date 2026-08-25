import Foundation
import Observation

/// Which chord opens the clipboard picker, and whether it is on at all.
@MainActor
@Observable
final class HotKeyPreferences {

    private enum Key {
        static let clipPickerEnabled = "hotkey.clipPicker.enabled"
        static let clipPickerSpec = "hotkey.clipPicker.spec"
    }

    var clipPickerEnabled: Bool {
        didSet { defaults.set(clipPickerEnabled, forKey: Key.clipPickerEnabled) }
    }

    /// The id of the chosen preset. Stored by id rather than by key code so a
    /// future change to a preset's chord travels with the app.
    var clipPickerSpecID: String {
        didSet { defaults.set(clipPickerSpecID, forKey: Key.clipPickerSpec) }
    }

    var clipPickerSpec: HotKeySpec {
        HotKeyCenter.spec(id: clipPickerSpecID) ?? HotKeyCenter.defaultSpec
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clipPickerEnabled = defaults.object(forKey: Key.clipPickerEnabled) as? Bool ?? true
        clipPickerSpecID = defaults.string(forKey: Key.clipPickerSpec) ?? HotKeyCenter.defaultSpec.id
    }
}
