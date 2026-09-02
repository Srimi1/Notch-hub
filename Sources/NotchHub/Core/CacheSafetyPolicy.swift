import Foundation

/// The rules that decide which cache folders may be offered, and — separately,
/// again, at the moment of trashing — which may actually be moved.
///
/// Adapted from Purge's `DeletionSafetyPolicy` and `SafetyTierList` (Jithin
/// Sabu, MIT — see `Vendor/purge-app`). Everything here is a pure function
/// over names and paths; nothing touches the disk, which is what lets the
/// tests pin every rule without a fixture folder.
///
/// The shape is an allowlist with a deny-list on top. A folder is offered only
/// when something recognises it (the catalog or the tier list), and even then
/// only if no protected-name rule refuses it first. Unknown folders are not
/// "unsafe"; they are simply never mentioned.
enum CacheSafetyPolicy {

    // MARK: - Protected names under ~/Library/Caches

    /// Identity and account daemons whose caches must never be offered.
    ///
    /// CloudKit and FamilyCircle are macOS-protected outright. The rest are
    /// deletable, but wiping them makes accountsd, akd and friends lose their
    /// cached authorisation state and re-hit the login keychain for every
    /// service — the storm of "… wants to use the login keychain" prompts.
    /// The space they hold is negligible anyway.
    static let protectedCachesFolderNames: Set<String> = [
        "CloudKit",
        "FamilyCircle",
        "com.apple.accountsd",
        "com.apple.appleaccountd",
        "com.apple.amsaccountsd",
        "com.apple.akd",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.identityservicesd",
        "com.apple.iCloudHelper",
        "com.apple.icloudwebd",
        "com.apple.itunescloudd",
        "com.apple.iCloudNotificationAgent",
        "PassKit"
    ]

    /// Case-insensitive fragments that mark a folder as identity, sign-in or
    /// payment state. Substring rather than prefix, because the offenders are
    /// spread across naming conventions; specific enough (`authkit`, not
    /// `auth`) not to swallow ordinary words. Over-matching is the safe
    /// direction: the folder is just not offered.
    static let protectedCachesFolderFragments: [String] = [
        "account",
        "icloud",
        "itunescloud",
        "appleid",
        "authkit",
        "authentication",
        "authorization",
        "identityservice",
        "keychain",
        "passkit"
    ]

    /// Caches the catalog calls safe but macOS guards behind Full Disk Access.
    /// Without the grant they size as nothing and refuse to move, which would
    /// leave a permanent "1 could not be moved" on the panel.
    static let cachesRequiringFullDiskAccess: Set<String> = [
        "com.apple.Safari",
        "com.apple.Safari.SafeBrowsing"
    ]

    /// Folders under `~/Library/Logs` that macOS refuses to remove.
    static let protectedLogFolderNames: Set<String> = [
        "DiagnosticReportsForNewHardware"
    ]

    /// Crash reports are logs too, but a developer may want to read one before
    /// it goes — so they are counted as "check first", not moved on one click.
    static let checkFirstLogFolderNames: Set<String> = [
        "DiagnosticReports"
    ]

    // MARK: - Protected sandboxed containers

    static let protectedContainerBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.Home",
        "com.apple.homed",
        "com.apple.HomeKit"
    ]

    /// Apple's account, authentication and password stack. Clearing their
    /// caches forces the identity daemons to re-authorise — the same keychain
    /// prompt storm as above.
    static let protectedContainerBundleIDPrefixes: [String] = [
        "com.apple.Passwords",
        "com.apple.AuthKit",
        "com.apple.AppleAccount",
        "com.apple.Accounts",
        "com.apple.PassKit",
        "com.apple.Internet-Accounts"
    ]

    // MARK: - Tier list (the fallback when the catalog does not know a name)

    /// Folder names that are always regenerated with zero data loss.
    static let definitelySafeFolderNames: Set<String> = [
        "node_modules", "DerivedData", ".next", ".nuxt", ".turbo", ".parcel-cache", "__pycache__",
        ".gradle", "target", "build", "dist", "out", ".cache", "venv", ".venv", "_cacache", "_npx",
        "_logs", "GPUCache", "ShaderCache", "CachedData", "Code Cache", "DawnWebGPUCache",
        "component_crx_cache", "CacheStorage", "ScriptCache", "DocumentationCache", "LinkThumbnail",
        "ChatMedia", "AppInstallationBinaryDeltas", "corepack", "Homebrew", "yarn", "pnpm", "pip",
        "cocoapods", "Pods", ".dart_tool"
    ]

    /// Bundle-identifier prefixes whose caches apps recreate on their own.
    static let definitelySafeBundlePrefixes: [String] = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser",
        "company.thebrowser.Browser", "com.spotify.client", "com.tinyspeck.slackmacgap",
        "com.figma.desktop", "us.zoom.xos", "com.microsoft.VSCode", "com.todesktop", "com.raycast.macos",
        "com.runningwithcrayons.Alfred", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "notion.id", "com.linear", "com.loom.desktop", "com.grammarly", "com.ollama.ollama",
        "com.microsoft.teams"
    ]

    /// Folders that hold user data, a sync state, or an index the system has
    /// to rebuild. Deletable, but each costs the user something visible.
    static let checkFirstFolderNames: Set<String> = [
        "com.apple.Spotlight", "com.apple.mail", "com.apple.Photos", "com.apple.Music", "com.apple.Maps",
        "com.apple.GeoServices", "com.dropbox.client2", "com.google.GoogleDrive", "com.google.drivefs",
        "com.microsoft.OneDrive", "com.apple.cloudd", "com.1password.1password", "com.apple.icloud"
    ]

    // MARK: - Never-delete locations (checked again at trash time)

    /// Locations whose path, or any descendant, must never be moved.
    static func neverDeletePrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Keychains",
            "\(home)/Library/Preferences",
            "\(home)/Library/Mail",
            "\(home)/Library/Application Support/MobileSync",
            "\(home)/System",
            "\(home)/Pictures",
            "\(home)/Music",
            "\(home)/Movies",
            "/Library", "/usr", "/bin", "/sbin", "/etc", "/var"
        ]
    }

    /// User content roots that are off-limits themselves, while allowed caches
    /// nested below `~/Library` remain reachable.
    static func neverDeleteExactPaths(home: String) -> [String] {
        [
            home,
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads"
        ]
    }

    // MARK: - Classification

    /// What a `~/Library/Caches` child folder is, if it is anything at all.
    struct Classification: Equatable, Sendable {
        let level: CacheSafetyLevel
        let title: String
        let scope: CacheCatalog.Scope
    }

    static func isProtectedCachesFolder(_ name: String) -> Bool {
        if protectedCachesFolderNames.contains(name) { return true }
        let lowered = name.lowercased()
        return protectedCachesFolderFragments.contains { lowered.contains($0) }
    }

    /// Classify a top-level folder of `~/Library/Caches`, in the order Purge
    /// uses: protected names refuse first, then the catalog, then the tier
    /// list. `nil` means "not offered" — it is not a verdict on the folder.
    static func classify(
        cachesFolderNamed name: String,
        includeDeveloperCaches: Bool,
        fullDiskAccess: Bool
    ) -> Classification? {
        guard !isProtectedCachesFolder(name) else { return nil }
        if !fullDiskAccess, cachesRequiringFullDiskAccess.contains(name) { return nil }

        if let entry = CacheCatalog.lookup(name) {
            if entry.scope == .devTools, !includeDeveloperCaches { return nil }
            return Classification(level: entry.level, title: entry.displayName, scope: entry.scope)
        }
        guard let level = tierListLevel(for: name) else { return nil }
        return Classification(level: level, title: name, scope: .appCaches)
    }

    /// Purge's `SafetyTierList` rules for a bare folder name.
    static func tierListLevel(for name: String) -> CacheSafetyLevel? {
        let lowered = name.lowercased()
        if definitelySafeFolderNames.contains(where: { $0.lowercased() == lowered }) { return .safe }
        if definitelySafeBundlePrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return .safe }
        if checkFirstFolderNames.contains(where: { $0.lowercased() == lowered }) { return .medium }
        if lowered.hasSuffix(".shipit") { return .safe }
        return nil
    }

    /// Classify a child of `~/Library/Logs`.
    static func classify(logEntryNamed name: String) -> Classification? {
        if protectedLogFolderNames.contains(name) { return nil }
        let level: CacheSafetyLevel = checkFirstLogFolderNames.contains(name) ? .medium : .safe
        return Classification(level: level, title: name, scope: .appCaches)
    }

    static func isProtectedContainerBundleID(_ bundleID: String) -> Bool {
        if protectedContainerBundleIDs.contains(bundleID) { return true }
        return protectedContainerBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Classify a sandboxed container by its bundle identifier. Unknown apps
    /// are never entered — that is also what keeps the scan short on a Mac
    /// with hundreds of containers.
    static func classify(containerBundleID bundleID: String, includeDeveloperCaches: Bool) -> Classification? {
        guard !isProtectedContainerBundleID(bundleID) else { return nil }
        if let entry = CacheCatalog.lookup(bundleID) {
            if entry.scope == .devTools, !includeDeveloperCaches { return nil }
            return Classification(level: entry.level, title: entry.displayName, scope: entry.scope)
        }
        let lowered = bundleID.lowercased()
        guard definitelySafeBundlePrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) else { return nil }
        return Classification(level: .safe, title: bundleID, scope: .appCaches)
    }

    // MARK: - Trash-time gate

    enum TrashDecision: Equatable, Sendable {
        case allowed
        case refused(Refusal)
    }

    enum Refusal: Equatable, Sendable {
        /// Only `.safe` items may move; a check-first item never can.
        case notSafe
        case outsideHome
        case protectedLocation
        case notAnAllowedLocation

        var description: String {
            switch self {
            case .notSafe: "not classified safe"
            case .outsideHome: "outside the home folder"
            case .protectedLocation: "a protected location"
            case .notAnAllowedLocation: "not a recognised cache location"
            }
        }
    }

    /// The scan roots. Their children are candidates; the roots themselves
    /// never are.
    static func scanRoots(home: String) -> [String] {
        ["\(home)/Library/Caches", "\(home)/Library/Logs", "\(home)/Library/Containers"]
    }

    /// Absolute developer-cache paths the switch can offer, from the catalog table.
    static func devToolAbsolutePaths(home: String) -> Set<String> {
        var paths = Set<String>()
        for cache in CacheCatalog.devToolCaches {
            for relative in cache.relativePaths {
                paths.insert(URL(fileURLWithPath: "\(home)/\(relative)").standardizedFileURL.path)
            }
        }
        return paths
    }

    /// Decide, immediately before `trashItem`, whether a URL may move.
    ///
    /// This runs on every item even though the scan already classified it:
    /// the candidate list is state that outlives the scan, and a path is
    /// standardised here so `..` cannot walk a candidate somewhere it was not
    /// found. Refusals are counted and logged by the caller, never dropped.
    static func trashDecision(for url: URL, level: CacheSafetyLevel, home: URL) -> TrashDecision {
        guard level == .safe else { return .refused(.notSafe) }
        return locationDecision(for: url, home: home)
    }

    /// The location half of `trashDecision`, on its own so the scan can check
    /// a developer-cache path has an allowed shape before offering it.
    static func locationDecision(for url: URL, home: URL) -> TrashDecision {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return .refused(.outsideHome) }

        if neverDeleteExactPaths(home: homePath).contains(path) { return .refused(.protectedLocation) }
        if scanRoots(home: homePath).contains(path) { return .refused(.protectedLocation) }
        if neverDeletePrefixes(home: homePath).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .refused(.protectedLocation)
        }

        return isAllowedShape(path, home: homePath) ? .allowed : .refused(.notAnAllowedLocation)
    }

    /// The only shapes a movable path can take.
    private static func isAllowedShape(_ path: String, home: String) -> Bool {
        let relative = path.dropFirst(home.count + 1)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        switch components.count {
        case 3 where components[0] == "Library" && components[1] == "Caches":
            return !isProtectedCachesFolder(components[2])
        case 3 where components[0] == "Library" && components[1] == "Logs":
            return !protectedLogFolderNames.contains(components[2])
        case 7 where components[0] == "Library" && components[1] == "Containers"
            && components[3] == "Data" && components[4] == "Library" && components[5] == "Caches":
            return !isProtectedContainerBundleID(components[2])
        default:
            return devToolAbsolutePaths(home: home).contains(path)
        }
    }
}
