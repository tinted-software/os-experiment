// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Swix",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "Swix",
            targets: ["Swix"]
        ),
        .executable(
            name: "swix",
            targets: ["SwixCLI"]
        ),
    ],
    targets: [
        .target(
            name: "Swix",
            path: "Sources/Swix"
        ),
        .executableTarget(
            name: "SwixCLI",
            dependencies: ["Swix"],
            path: "Sources/SwixCLI"
        ),
        .testTarget(
            name: "SwixTests",
            dependencies: ["Swix"],
            path: "Tests/SwixTests"
        ),
    ]
)
