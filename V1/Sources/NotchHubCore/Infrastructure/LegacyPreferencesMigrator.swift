import Foundation

public struct V1PreferenceState: Equatable, Sendable {
    public let visibleCapabilities: [AppCapability]
    public let lastActiveCapability: AppCapability
    public let clipboardHotKeyEnabled: Bool
    public let clipboardDoubleTapEnabled: Bool
    public let clipboardHotKeyID: String?
    public let copyPopupEnabled: Bool
    public let chargingPopupEnabled: Bool
    public let autoPasteEnabled: Bool
}

public enum LegacyMigrationResult: Equatable, Sendable {
    case alreadyCompleted
    case migrated(V1PreferenceState)
}

@MainActor
public enum LegacyPreferencesMigrator {
    public static let migrationVersion = 1

    private enum LegacyKey {
        static let visibleModules = "visibleModules"
        static let lastActiveModule = "lastActiveModule"
        static let clipboardHotKeyEnabled = "hotkey.clipPicker.enabled"
        static let clipboardDoubleTapEnabled = "hotkey.clipPicker.doubleTapN"
        static let clipboardHotKeyID = "hotkey.clipPicker.spec"
        static let copyPopupEnabled = "hud.copyPopup"
        static let chargingPopupEnabled = "hud.chargingPopup"
        static let autoPasteEnabled = "hud.autoPaste"
    }

    private enum V1Key {
        static let migrationVersion = "v1.migration.legacyPreferences"
        static let visibleCapabilities = "v1.visibleCapabilities"
        static let lastActiveCapability = "v1.lastActiveCapability"
        static let clipboardHotKeyEnabled = "v1.hotkey.clipboard.enabled"
        static let clipboardDoubleTapEnabled = "v1.hotkey.clipboard.doubleTap"
        static let clipboardHotKeyID = "v1.hotkey.clipboard.preset"
        static let copyPopupEnabled = "v1.hud.copy.enabled"
        static let chargingPopupEnabled = "v1.hud.charging.enabled"
        static let autoPasteEnabled = "v1.clipboard.autoPaste.enabled"
    }

    public static func migrate(
        from legacy: UserDefaults,
        to destination: UserDefaults
    ) -> LegacyMigrationResult {
        if destination.integer(forKey: V1Key.migrationVersion) >= migrationVersion {
            return .alreadyCompleted
        }
        let state = state(from: legacy)
        destination.set(state.visibleCapabilities.map(\.rawValue), forKey: V1Key.visibleCapabilities)
        destination.set(state.lastActiveCapability.rawValue, forKey: V1Key.lastActiveCapability)
        destination.set(state.clipboardHotKeyEnabled, forKey: V1Key.clipboardHotKeyEnabled)
        destination.set(state.clipboardDoubleTapEnabled, forKey: V1Key.clipboardDoubleTapEnabled)
        if let hotKeyID = state.clipboardHotKeyID {
            destination.set(hotKeyID, forKey: V1Key.clipboardHotKeyID)
        }
        destination.set(state.copyPopupEnabled, forKey: V1Key.copyPopupEnabled)
        destination.set(state.chargingPopupEnabled, forKey: V1Key.chargingPopupEnabled)
        destination.set(state.autoPasteEnabled, forKey: V1Key.autoPasteEnabled)
        destination.set(migrationVersion, forKey: V1Key.migrationVersion)
        return .migrated(state)
    }

    private static func state(from defaults: UserDefaults) -> V1PreferenceState {
        V1PreferenceState(
            visibleCapabilities: visibleCapabilities(from: defaults),
            lastActiveCapability: lastActiveCapability(from: defaults),
            clipboardHotKeyEnabled: bool(
                from: defaults,
                key: LegacyKey.clipboardHotKeyEnabled,
                fallback: true
            ),
            clipboardDoubleTapEnabled: bool(
                from: defaults,
                key: LegacyKey.clipboardDoubleTapEnabled,
                fallback: true
            ),
            clipboardHotKeyID: boundedIdentifier(defaults.string(forKey: LegacyKey.clipboardHotKeyID)),
            copyPopupEnabled: bool(from: defaults, key: LegacyKey.copyPopupEnabled, fallback: true),
            chargingPopupEnabled: bool(from: defaults, key: LegacyKey.chargingPopupEnabled, fallback: true),
            autoPasteEnabled: bool(from: defaults, key: LegacyKey.autoPasteEnabled, fallback: true)
        )
    }

    private static func visibleCapabilities(from defaults: UserDefaults) -> [AppCapability] {
        let rawModules = defaults.array(forKey: LegacyKey.visibleModules) as? [String] ?? []
        var values: [AppCapability] = [.agents]
        for rawModule in rawModules {
            guard let capability = mappedCapability(rawModule), !values.contains(capability) else {
                continue
            }
            values.append(capability)
        }
        if values.count == 1, rawModules.isEmpty {
            values.append(contentsOf: [.dashboard, .media, .clipboard, .focus])
        }
        return values
    }

    private static func lastActiveCapability(from defaults: UserDefaults) -> AppCapability {
        guard let value = defaults.string(forKey: LegacyKey.lastActiveModule) else {
            return .agents
        }
        return mappedCapability(value) ?? .agents
    }

    private static func mappedCapability(_ rawValue: String) -> AppCapability? {
        switch rawValue {
        case "dashboard": .dashboard
        case "media": .media
        case "clipboard": .clipboard
        case "focus": .focus
        default: nil
        }
    }

    private static func bool(
        from defaults: UserDefaults,
        key: String,
        fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func boundedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
        let result = String(String.UnicodeScalarView(allowed)).prefix(64)
        return result.isEmpty ? nil : String(result)
    }
}
