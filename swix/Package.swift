// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Swix",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "Swix",
            targets: ["Swix"]
        ),
    ],
    targets: [
        .target(
            name: "Swix",
            path: "Sources/Swix"
        ),
        .testTarget(
            name: "SwixTests",
            dependencies: ["Swix"],
            path: "Tests/SwixTests"
        ),
    ]
)
