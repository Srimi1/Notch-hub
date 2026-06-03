import Combine
import Foundation

/// Persists which feature modules appear in the expanded dashboard and which
/// module was last active, so NotchHub restores the user's layout across launches.
///
/// Modules are stored as raw string IDs in `UserDefaults` and **validated against
/// `FeatureModule.allCases` on load** — a renamed or removed enum case is silently
/// dropped rather than crashing or corrupting the saved layout. This is the one
/// place the project's "schema versioning" rule genuinely applies.
final class ModulePreferences: ObservableObject {

    private enum Key {
        static let visibleModules = "visibleModules"
        static let lastActiveModule = "lastActiveModule"
    }

    /// Dashboard layout for a fresh install (matches the modules backed by real
    /// services today).
    static let defaultVisibleModules: [FeatureModule] =
        [.dashboard, .media, .calendar, .aiCoding, .clipboard, .focus, .ramCleaner]

    /// Modules shown in the toggle band, kept in canonical (enum-declaration) order.
    @Published var visibleModules: [FeatureModule] {
        didSet { defaults.set(visibleModules.map(\.rawValue), forKey: Key.visibleModules) }
    }

    /// The module to reopen on launch.
    @Published var lastActiveModule: FeatureModule {
        didSet { defaults.set(lastActiveModule.rawValue, forKey: Key.lastActiveModule) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        visibleModules = Self.loadVisibleModules(from: defaults)
        lastActiveModule = Self.loadLastActiveModule(from: defaults)
    }

    // MARK: - Mutations

    func isVisible(_ module: FeatureModule) -> Bool {
        visibleModules.contains(module)
    }

    /// Show or hide a module, preserving canonical order so the toggle band layout
    /// is stable regardless of toggle sequence.
    func setModule(_ module: FeatureModule, visible: Bool) {
        if visible {
            guard !visibleModules.contains(module) else { return }
            let next = visibleModules + [module]
            visibleModules = FeatureModule.allCases.filter(next.contains)
        } else {
            visibleModules.removeAll { $0 == module }
        }
    }

    // MARK: - Loading

    private static func loadVisibleModules(from defaults: UserDefaults) -> [FeatureModule] {
        guard let raw = defaults.array(forKey: Key.visibleModules) as? [String] else {
            return defaultVisibleModules
        }
        // Drop any IDs that no longer map to a known module (survives enum renames).
        let restored = raw.compactMap(FeatureModule.init(rawValue:))
        return restored.isEmpty ? defaultVisibleModules : restored
    }

    private static func loadLastActiveModule(from defaults: UserDefaults) -> FeatureModule {
        guard let raw = defaults.string(forKey: Key.lastActiveModule),
              let module = FeatureModule(rawValue: raw)
        else {
            return .dashboard
        }
        return module
    }
}
