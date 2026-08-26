// swift-tools-version: 5.9
import Foundation
import PackageDescription

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

// Swift 5.9 remains the declared tools version while legacy strict-concurrency
// warnings are migrated. New code should stay clean under
// `-strict-concurrency=complete` before the package moves to Swift 6 mode.

let package = Package(
    name: "NotchHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Prebuilt SwiftLint binary artifact (no SwiftSyntax recompile).
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.3"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
        // The only runtime dependency. Lottie is the reference player for
        // Bodymovin JSON; the notch's astronaut is played by it verbatim rather
        // than approximated. SwiftPM links it statically, so the app bundle
        // needs no embedded framework.
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
    ],
    targets: [
        .executableTarget(
            name: "NotchHub",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios"),
            ],
            path: "Sources/NotchHub",
            // A stray vector database sits in the source tree and is gitignored;
            // without this SwiftPM warns about an unhandled file on every build.
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
