import Foundation

/// How much a cache folder can be trusted to be rebuildable.
///
/// Two tiers, deliberately. Purge's catalog — which this one is converted
/// from — has no "never delete" tier: anything dangerous is simply absent from
/// the allowlist and therefore never offered. `medium` is "check first": the
/// folder regenerates, but losing it costs the user something visible (a
/// re-index, a re-sync, a sign-in), so it is counted and shown but never
/// moved by the one-click clean.
enum CacheSafetyLevel: String, Sendable, Codable, Equatable {
    case safe
    case medium

    /// Whether this is the more cautious of two readings — used when two
    /// catalog entries claim the same folder name.
    var isMoreConservative: Bool { self == .medium }
}

/// The folder-name catalog behind the cache cleanup: which `~/Library/Caches`
/// entries (and developer caches) are known, what they are called, and how
/// safe they are to move to the Trash.
///
/// Converted from Purge's `explanations.json` by
/// `scripts/generate-cache-catalog.py` into the two generated tables in
/// `CacheCatalog+Apps.swift` and `CacheCatalog+DevTools.swift`. It is a Swift
/// table rather than a bundled JSON file because the package declares no
/// SwiftPM resources and the tests run without an app bundle.
enum CacheCatalog {

    enum Scope: Sendable, Equatable {
        /// An application's own cache, offered to everyone.
        case appCaches
        /// A build or package-manager cache, offered only with the developer
        /// switch in Settings — for most people these folders do not exist,
        /// and for a developer they are the ones worth a moment's thought.
        case devTools
    }

    struct Entry: Sendable, Equatable {
        let key: String
        let displayName: String
        let level: CacheSafetyLevel
        let scope: Scope
        /// Folder names this entry matches, case-insensitively.
        let aliases: [String]
        /// Bundle identifiers this entry matches, case-insensitively.
        let bundleIDs: [String]
    }

    /// A developer cache that lives outside `~/Library/Caches`, named by the
    /// catalog entry that classifies it. Paths are relative to the home folder.
    struct DevToolCache: Sendable, Equatable {
        let catalogKey: String
        let relativePaths: [String]
    }

    static let entries: [Entry] = appEntries + devToolEntries

    /// The entry whose key, alias or bundle identifier is `name`, ignoring case.
    ///
    /// Keys win over aliases, which win over bundle identifiers. When two
    /// entries claim the same name (Purge's `.gradle` is both the safe Gradle
    /// cache and the check-first Android SDK), the more cautious level wins —
    /// a folder that might be either is treated as the one worth checking.
    static func lookup(_ name: String) -> Entry? {
        index[name.lowercased()]
    }

    static func entry(forKey key: String) -> Entry? {
        byKey[key.lowercased()]
    }

    // MARK: - Index

    private static let byKey: [String: Entry] = Dictionary(
        entries.map { ($0.key.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    private static let index: [String: Entry] = buildIndex(entries)

    /// Names are added in precedence order — every key, then every alias, then
    /// every bundle identifier — so a later, weaker match never displaces an
    /// earlier, stronger one unless it is the more cautious reading.
    static func buildIndex(_ entries: [Entry]) -> [String: Entry] {
        var index: [String: Entry] = [:]
        func add(_ name: String, _ entry: Entry) {
            let lowered = name.lowercased()
            guard !lowered.isEmpty else { return }
            if let existing = index[lowered] {
                if entry.level.isMoreConservative, !existing.level.isMoreConservative {
                    index[lowered] = entry
                }
                return
            }
            index[lowered] = entry
        }
        for entry in entries { add(entry.key, entry) }
        for entry in entries { entry.aliases.forEach { add($0, entry) } }
        for entry in entries { entry.bundleIDs.forEach { add($0, entry) } }
        return index
    }

    /// The generated tables call this so each row stays on one line.
    static func entry(
        _ key: String,
        _ displayName: String,
        _ level: CacheSafetyLevel,
        _ scope: Scope,
        aliases: [String] = [],
        bundleIDs: [String] = []
    ) -> Entry {
        Entry(key: key, displayName: displayName, level: level, scope: scope, aliases: aliases, bundleIDs: bundleIDs)
    }
}
