import Foundation

/// Developer caches that live outside `~/Library/Caches`, so the scan has to
/// be told where to look. Offered only with "Include developer caches" on.
///
/// The list is Purge's `DevScanner` catalog with the entries that are not
/// really caches left out: Docker's disk image, `~/.android` (adb keys and
/// emulators), shell history, `~/.flutter`, installed gems and sbt plugins,
/// JetBrains and Zed settings, and VS Code's per-project `workspaceStorage`.
/// Every key here must name a catalog entry — a test checks that — because
/// the entry is what supplies the level and the title.
extension CacheCatalog {
    static let devToolCaches: [DevToolCache] = [
        DevToolCache(catalogKey: "DerivedData", relativePaths: ["Library/Developer/Xcode/DerivedData"]),
        DevToolCache(catalogKey: "xcode-docs-cache", relativePaths: ["Library/Developer/Xcode/DocumentationCache"]),
        DevToolCache(catalogKey: "xcode-device-support", relativePaths: ["Library/Developer/Xcode/iOS DeviceSupport"]),
        DevToolCache(catalogKey: "xcode-archives", relativePaths: ["Library/Developer/Xcode/Archives"]),
        DevToolCache(catalogKey: "npm-cache", relativePaths: [".npm/_cacache"]),
        DevToolCache(catalogKey: "npm-npx-cache", relativePaths: [".npm/_npx"]),
        DevToolCache(catalogKey: "npm-logs", relativePaths: [".npm/_logs"]),
        DevToolCache(catalogKey: "corepack-cache", relativePaths: [".cache/node/corepack"]),
        DevToolCache(catalogKey: "pnpm-store", relativePaths: [".pnpm-store"]),
        DevToolCache(catalogKey: "bun-cache", relativePaths: [".bun/install/cache"]),
        DevToolCache(catalogKey: "cocoapods-cache", relativePaths: [".cocoapods/repos"]),
        DevToolCache(catalogKey: "swiftpm-cache", relativePaths: [".swiftpm/cache"]),
        DevToolCache(catalogKey: "gradle-cache", relativePaths: [".gradle/caches"]),
        DevToolCache(catalogKey: "maven", relativePaths: [".m2/repository"]),
        DevToolCache(catalogKey: "sbt", relativePaths: [".ivy2/cache"]),
        DevToolCache(catalogKey: "go", relativePaths: ["go/pkg/mod/cache", ".cache/go-build"]),
        DevToolCache(catalogKey: "cargo", relativePaths: [".cargo/registry", ".cargo/git"]),
        DevToolCache(catalogKey: "composer", relativePaths: [".composer/cache"]),
        DevToolCache(catalogKey: "bundler", relativePaths: [".bundle/cache"]),
        DevToolCache(catalogKey: "hex-packages", relativePaths: [".hex/packages"]),
        DevToolCache(catalogKey: "rebar3-cache", relativePaths: [".cache/rebar3"]),
        DevToolCache(catalogKey: "nuget-packages", relativePaths: [".nuget/packages"]),
        DevToolCache(catalogKey: "cabal-packages", relativePaths: [".cabal/packages"]),
        DevToolCache(catalogKey: "stack-global", relativePaths: [".stack"]),
        DevToolCache(catalogKey: "bazel-cache", relativePaths: [".cache/bazel"]),
        DevToolCache(catalogKey: "terraform", relativePaths: [".terraform.d/plugin-cache"]),
        DevToolCache(catalogKey: "githubactions", relativePaths: [".cache/act"]),
        DevToolCache(catalogKey: "vagrant", relativePaths: [".vagrant.d/boxes", ".vagrant.d/tmp"]),
        DevToolCache(
            catalogKey: "vscode",
            relativePaths: [
                "Library/Application Support/Code/Cache",
                "Library/Application Support/Code/CachedData",
                "Library/Application Support/Code/CachedExtensionVSIXs"
            ]
        ),
        DevToolCache(
            catalogKey: "cursor",
            relativePaths: [
                "Library/Application Support/Cursor/Cache",
                "Library/Application Support/Cursor/CachedData"
            ]
        )
    ]
}
