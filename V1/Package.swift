// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NotchHubV1",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "NotchHubSafeFeatures", targets: ["NotchHubSafeFeatures"]),
        .library(name: "NotchHubCore", targets: ["NotchHubCore"]),
        .executable(name: "NotchHubV1", targets: ["NotchHubV1"]),
        .executable(name: "NotchHubLite", targets: ["NotchHubLite"]),
        .executable(name: "NotchHubHookBridge", targets: ["NotchHubHookBridge"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SimplyDanny/SwiftLintPlugins",
            from: "0.63.3"
        ),
        .package(
            url: "https://github.com/nicklockwood/SwiftFormat",
            from: "0.59.1"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.6"
        ),
    ],
    targets: [
        .target(
            name: "NotchHubSafeFeatures",
            path: "Sources/NotchHubSafeFeatures"
        ),
        .target(
            name: "NotchHubCore",
            dependencies: ["NotchHubSafeFeatures"],
            path: "Sources/NotchHubCore"
        ),
        .executableTarget(
            name: "NotchHubV1",
            dependencies: [
                "NotchHubCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/NotchHubV1"
        ),
        .executableTarget(
            name: "NotchHubLite",
            dependencies: ["NotchHubSafeFeatures"],
            path: "Sources/NotchHubLite"
        ),
        .executableTarget(
            name: "NotchHubHookBridge",
            dependencies: ["NotchHubCore"],
            path: "Sources/NotchHubHookBridge"
        ),
        .testTarget(
            name: "NotchHubCoreTests",
            dependencies: ["NotchHubCore"],
            path: "Tests/NotchHubCoreTests"
        ),
        .testTarget(
            name: "NotchHubSafeFeaturesTests",
            dependencies: ["NotchHubSafeFeatures"],
            path: "Tests/NotchHubSafeFeaturesTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
