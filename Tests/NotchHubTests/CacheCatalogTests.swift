import Foundation
import Testing
@testable import NotchHub

/// The catalog is a converted copy of someone else's data, and the conversion
/// is a script. What these tests defend is the conversion: that every name
/// still resolves, that a name claimed twice resolves the cautious way, and
/// that the developer-cache table cannot name an entry that is not there.
@Suite("Cache catalog")
struct CacheCatalogTests {

    @Test
    func theCatalogKeepsBothHalvesOfTheSourceData() {
        #expect(CacheCatalog.appEntries.count == 147)
        #expect(CacheCatalog.devToolEntries.count == 103)
        #expect(CacheCatalog.entries.count == 250)
    }

    @Test
    func noTwoEntriesShareAKey() {
        var seen = Set<String>()
        for entry in CacheCatalog.entries {
            #expect(seen.insert(entry.key.lowercased()).inserted, "duplicate key \(entry.key)")
        }
    }

    /// Folder names arrive from the filesystem in whatever case the app that
    /// made them chose, so every lookup path has to be case-insensitive.
    @Test
    func lookupIgnoresCase() {
        #expect(CacheCatalog.lookup("deriveddata")?.key == "DerivedData")
        #expect(CacheCatalog.lookup("DERIVEDDATA")?.key == "DerivedData")
        #expect(CacheCatalog.lookup("com.google.chrome")?.key == "chrome")
        #expect(CacheCatalog.entry(forKey: "DERIVEDDATA")?.displayName == "Xcode Build Files")
    }

    @Test
    func anUnknownNameIsNotInTheCatalog() {
        #expect(CacheCatalog.lookup("com.example.notchhubtest") == nil)
        #expect(CacheCatalog.entry(forKey: "no-such-key") == nil)
    }

    /// `.gradle` is claimed by both the safe Gradle cache and the check-first
    /// Android SDK. A folder that might be either has to be the one worth
    /// checking, or one-click cleaning would take the SDK with it.
    @Test
    func aNameClaimedTwiceResolvesToTheMoreCautiousEntry() {
        #expect(CacheCatalog.lookup(".gradle")?.level == .medium)
    }

    /// A key always beats an alias belonging to a different entry — otherwise
    /// the table's own identifiers would depend on declaration order.
    @Test
    func aKeyOutranksAnotherEntrysAlias() {
        for entry in CacheCatalog.entries where entry.level == .medium {
            #expect(CacheCatalog.lookup(entry.key)?.key == entry.key)
        }
    }

    @Test
    func scopesSurviveTheConversion() {
        #expect(CacheCatalog.lookup("Homebrew")?.scope == .devTools)
        #expect(CacheCatalog.lookup("com.spotify.client")?.scope == .appCaches)
        #expect(CacheCatalog.appEntries.allSatisfy { $0.scope == .appCaches })
        #expect(CacheCatalog.devToolEntries.allSatisfy { $0.scope == .devTools })
    }

    /// The developer-cache table supplies paths but not levels; the catalog
    /// entry does. A key with no entry would be a path with no classification.
    @Test
    func everyDeveloperCacheNamesARealCatalogEntry() {
        for tool in CacheCatalog.devToolCaches {
            #expect(CacheCatalog.entry(forKey: tool.catalogKey) != nil, "no entry for \(tool.catalogKey)")
            #expect(!tool.relativePaths.isEmpty)
        }
    }

    /// Nothing in the table may be absolute or climb out of the home folder:
    /// they are joined onto the home directory unexamined.
    @Test
    func developerCachePathsStayInsideTheHomeFolder() {
        for tool in CacheCatalog.devToolCaches {
            for path in tool.relativePaths {
                #expect(!path.hasPrefix("/"), "\(path) is absolute")
                #expect(!path.contains(".."), "\(path) climbs out")
            }
        }
    }

    /// The index builder is the one piece of logic in the catalog, so it is
    /// tested directly rather than only through the 250-row table.
    @Test
    func theIndexPrefersKeysThenAliasesThenBundleIDs() {
        let alias = CacheCatalog.entry("first", "First", .safe, .appCaches, aliases: ["shared"])
        let bundle = CacheCatalog.entry("second", "Second", .safe, .appCaches, bundleIDs: ["shared"])
        let index = CacheCatalog.buildIndex([bundle, alias])
        #expect(index["shared"]?.key == "first")
    }
}
