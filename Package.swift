// swift-tools-version: 5.9
import Foundation
import PackageDescription

// swift-testing's framework lives under Command Line Tools when full Xcode is not
// installed; SwiftPM does not add that search path automatically. Add it only when
// it actually exists, so full-Xcode machines (where `Testing` resolves natively)
// are unaffected.
// swift-testing ships under Command Line Tools when full Xcode is absent. Both the
// framework and its private interop dylib must be locatable at compile, link, and
// run time; SwiftPM does not add these paths automatically.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltUsrLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let hasCLTTesting = FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
// Compile: where to find the Testing module.
let testCompileFlags: [String] = hasCLTTesting ? ["-F", cltFrameworks] : []
// Link + runtime: framework search path plus rpaths so dyld can load
// @rpath/Testing.framework and @rpath/lib_TestingInterop.dylib.
let testLinkFlags: [String] = hasCLTTesting
    ? ["-F", cltFrameworks,
       "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
       "-Xlinker", "-rpath", "-Xlinker", cltUsrLib]
    : []

// NOTE: Kept on tools-version 5.9 deliberately. The existing code produces 456
// strict-concurrency diagnostics that become hard errors under the Swift 6
// language mode (see CLAUDE.md "Swift 6 migration" tracking). Flipping the mode
// now would break the build, violating the "never break compilation" rule.
// Migrate incrementally, then bump to 6.0 with `.swiftLanguageMode(.v6)`.

let package = Package(
    name: "NotchHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Prebuilt SwiftLint binary artifact (no SwiftSyntax recompile).
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.3"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
    ],
    targets: [
        .executableTarget(
            name: "NotchHub",
            path: "Sources/NotchHub",
            exclude: ["ruvector.db"]
        ),
        .testTarget(
            name: "NotchHubTests",
            dependencies: ["NotchHub"],
            path: "Tests/NotchHubTests",
            swiftSettings: [.unsafeFlags(testCompileFlags)],
            linkerSettings: [.unsafeFlags(testLinkFlags)]
        ),
    ]
)
