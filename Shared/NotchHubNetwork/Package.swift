// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchHubNetwork",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "NotchHubNetwork", targets: ["NotchHubNetwork"]),
    ],
    targets: [
        .target(name: "NotchHubNetwork"),
        .testTarget(
            name: "NotchHubNetworkTests",
            dependencies: ["NotchHubNetwork"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
