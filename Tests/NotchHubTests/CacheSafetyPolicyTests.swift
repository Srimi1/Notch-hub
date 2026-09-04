import Foundation
import Testing
@testable import NotchHub

/// The rules that decide what may be offered and what may actually be moved.
///
/// This is the suite that stands between a user and a deleted Keychain. Every
/// case here is a path that must be refused, or a folder that must never even
/// be listed, and the reasons are the ones Purge learned in the wild: keychain
/// prompt storms from account daemons, and generic names like `build` that
/// mean nothing without their surroundings.
@Suite("Cache safety policy")
struct CacheSafetyPolicyTests {

    private let home = URL(fileURLWithPath: "/fixtures/home", isDirectory: true)

    private func caches(_ name: String) -> URL {
        home.appendingPathComponent("Library/Caches/\(name)", isDirectory: true)
    }

    // MARK: - What is never listed

    /// An exact protected name wins even though the catalog knows the folder
    /// and calls it something. `PassKit` is a catalog entry; it is still never
    /// offered.
    @Test
    func protectedNamesAreNeverOffered() {
        for name in CacheSafetyPolicy.protectedCachesFolderNames {
            let classification = CacheSafetyPolicy.classify(
                cachesFolderNamed: name, includeDeveloperCaches: true, fullDiskAccess: true
            )
            #expect(classification == nil, "\(name) was offered")
        }
    }

    /// The fragment rule exists so a daemon nobody has catalogued yet is
    /// refused by default. `com.google.Chrome` is a "definitely safe" prefix,
    /// but a keychain helper under that prefix still is not.
    @Test
    func anIdentityFragmentBeatsASafePrefix() {
        let classification = CacheSafetyPolicy.classify(
            cachesFolderNamed: "com.google.Chrome.keychainhelper", includeDeveloperCaches: true, fullDiskAccess: true
        )
        #expect(classification == nil)
        #expect(CacheSafetyPolicy.isProtectedCachesFolder("Com.Apple.AccountsD"))
        #expect(CacheSafetyPolicy.isProtectedCachesFolder("com.someapp.AppleIDHelper"))
    }

    /// Safari's cache is catalogued safe, but macOS guards it. Offering it
    /// without the grant produces a row that can never be cleaned.
    @Test
    func safariIsLeftOutUntilFullDiskAccessExists() {
        #expect(CacheSafetyPolicy.classify(
            cachesFolderNamed: "com.apple.Safari", includeDeveloperCaches: false, fullDiskAccess: false
        ) == nil)
        #expect(CacheSafetyPolicy.classify(
            cachesFolderNamed: "com.apple.Safari", includeDeveloperCaches: false, fullDiskAccess: true
        )?.level == .safe)
    }

    @Test
    func anUnknownFolderIsNotOffered() {
        #expect(CacheSafetyPolicy.classify(
            cachesFolderNamed: "com.example.notchhubtest", includeDeveloperCaches: true, fullDiskAccess: true
        ) == nil)
    }

    // MARK: - Levels

    /// The catalog is consulted before the tier list, and the catalog is the
    /// more careful of the two about Ollama's models.
    @Test
    func theCatalogOutranksTheTierList() {
        let classification = CacheSafetyPolicy.classify(
            cachesFolderNamed: "com.ollama.Ollama", includeDeveloperCaches: true, fullDiskAccess: true
        )
        #expect(classification?.level == .medium)
        #expect(CacheSafetyPolicy.tierListLevel(for: "com.ollama.Ollama") == .safe)
    }

    @Test
    func syncAndSearchCachesAreCheckFirst() {
        for name in CacheSafetyPolicy.checkFirstFolderNames where !CacheSafetyPolicy.isProtectedCachesFolder(name) {
            let classification = CacheSafetyPolicy.classify(
                cachesFolderNamed: name, includeDeveloperCaches: true, fullDiskAccess: true
            )
            #expect(classification?.level == .medium, "\(name) was not check-first")
        }
    }

    @Test
    func rebuildableCachesAreSafe() {
        #expect(CacheSafetyPolicy.tierListLevel(for: "GPUCache") == .safe)
        #expect(CacheSafetyPolicy.tierListLevel(for: "com.brave.Browser.helper") == .safe)
        #expect(CacheSafetyPolicy.tierListLevel(for: "com.anthropic.claudefordesktop.ShipIt") == .safe)
        #expect(CacheSafetyPolicy.tierListLevel(for: "com.example.unknown") == nil)
    }

    /// The developer switch is what keeps build caches out of a
    /// non-developer's panel, and it is enforced at classification time so
    /// they are never even sized.
    @Test
    func developerCachesAreHiddenUntilTheSwitchIsOn() {
        #expect(CacheSafetyPolicy.classify(
            cachesFolderNamed: "Homebrew", includeDeveloperCaches: false, fullDiskAccess: true
        ) == nil)
        #expect(CacheSafetyPolicy.classify(
            cachesFolderNamed: "Homebrew", includeDeveloperCaches: true, fullDiskAccess: true
        )?.scope == .devTools)
    }

    /// Crash reports regenerate, but a developer may want to read one first.
    @Test
    func crashReportsAreCheckFirstAndProtectedLogsAreNotOffered() {
        #expect(CacheSafetyPolicy.classify(logEntryNamed: "DiagnosticReports")?.level == .medium)
        #expect(CacheSafetyPolicy.classify(logEntryNamed: "DiagnosticReportsForNewHardware") == nil)
        #expect(CacheSafetyPolicy.classify(logEntryNamed: "Homebrew")?.level == .safe)
    }

    @Test
    func passwordAndHomeContainersAreNeverEntered() {
        #expect(CacheSafetyPolicy.classify(containerBundleID: "com.apple.Safari", includeDeveloperCaches: true) == nil)
        #expect(CacheSafetyPolicy.classify(
            containerBundleID: "com.apple.Passwords.Extension", includeDeveloperCaches: true
        ) == nil)
        #expect(CacheSafetyPolicy.classify(
            containerBundleID: "com.spotify.client", includeDeveloperCaches: false
        )?.level == .safe)
        #expect(CacheSafetyPolicy.classify(
            containerBundleID: "com.example.unknown", includeDeveloperCaches: true
        ) == nil)
    }

    // MARK: - The trash-time gate

    @Test
    func aCheckFirstItemCanNeverBeTrashed() {
        let decision = CacheSafetyPolicy.trashDecision(for: caches("com.apple.Spotlight"), level: .medium, home: home)
        #expect(decision == .refused(.notSafe))
    }

    /// The candidate list outlives the scan, so a path is standardised again
    /// here: `..` must not be able to walk a "safe" row into the Keychains.
    @Test
    func aPathThatClimbsOutIsRefused() {
        let sneaky = caches("../Keychains")
        #expect(CacheSafetyPolicy.trashDecision(for: sneaky, level: .safe, home: home) == .refused(.protectedLocation))
    }

    @Test
    func theScanRootsThemselvesAreRefused() {
        for root in CacheSafetyPolicy.scanRoots(home: home.path) {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            #expect(
                CacheSafetyPolicy.trashDecision(for: url, level: .safe, home: home) == .refused(.protectedLocation),
                "\(root) was allowed"
            )
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: library, level: .safe, home: home) == .refused(.protectedLocation))
    }

    @Test
    func userContentAndSystemPathsAreRefused() {
        let cases: [URL] = [
            home.appendingPathComponent("Documents/report.pdf"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads/installer.dmg"),
            home.appendingPathComponent("Library/Keychains/login.keychain-db"),
            home.appendingPathComponent("Library/Preferences/com.example.plist"),
            home.appendingPathComponent("Library/Application Support/MobileSync/Backup"),
            home.appendingPathComponent("Pictures/Photos Library.photoslibrary"),
            URL(fileURLWithPath: "/usr/local/bin/tool"),
            URL(fileURLWithPath: "/tmp/scratch")
        ]
        for url in cases {
            let decision = CacheSafetyPolicy.trashDecision(for: url, level: .safe, home: home)
            #expect(decision != .allowed, "\(url.path) was allowed")
        }
    }

    /// Only a direct child of a scan root may move. A path deeper inside a
    /// cache was never a candidate, so it is not one now.
    @Test
    func onlyDirectChildrenOfTheScanRootsAreAllowed() {
        #expect(CacheSafetyPolicy.trashDecision(for: caches("com.example"), level: .safe, home: home) == .allowed)
        let deeper = caches("com.example").appendingPathComponent("inner", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: deeper, level: .safe, home: home)
            == .refused(.notAnAllowedLocation))
    }

    @Test
    func protectedNamesAreRefusedAtTheGateToo() {
        #expect(CacheSafetyPolicy.trashDecision(for: caches("CloudKit"), level: .safe, home: home)
            == .refused(.notAnAllowedLocation))
        let log = home.appendingPathComponent("Library/Logs/DiagnosticReportsForNewHardware", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: log, level: .safe, home: home) == .refused(.notAnAllowedLocation))
    }

    @Test
    func containerCachesAreAllowedOnlyForUnprotectedApps() {
        let allowed = home.appendingPathComponent(
            "Library/Containers/com.spotify.client/Data/Library/Caches/Images", isDirectory: true
        )
        #expect(CacheSafetyPolicy.trashDecision(for: allowed, level: .safe, home: home) == .allowed)
        let refused = home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Caches/WebKit", isDirectory: true
        )

        #expect(CacheSafetyPolicy.trashDecision(for: refused, level: .safe, home: home)
            == .refused(.notAnAllowedLocation))
    }

    /// The developer table is the only way a path outside the scan roots can
    /// be moved, and it must be matched exactly rather than by prefix.
    @Test
    func onlyPathsInTheDeveloperTableAreAllowedOutsideTheRoots() {
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: derivedData, level: .safe, home: home) == .allowed)
        let sibling = home.appendingPathComponent("Library/Developer/Xcode/UserData", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: sibling, level: .safe, home: home)
            == .refused(.notAnAllowedLocation))
        let dotfolder = home.appendingPathComponent(".ssh", isDirectory: true)
        #expect(CacheSafetyPolicy.trashDecision(for: dotfolder, level: .safe, home: home)
            == .refused(.notAnAllowedLocation))
    }

    /// Every path the developer table can produce must pass the gate — a table
    /// entry the gate would refuse is a row that can be shown but never cleaned.
    @Test
    func everyDeveloperTablePathPassesTheGate() {
        for path in CacheSafetyPolicy.devToolAbsolutePaths(home: home.path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            #expect(CacheSafetyPolicy.trashDecision(for: url, level: .safe, home: home) == .allowed, "\(path) refused")
        }
    }
}
