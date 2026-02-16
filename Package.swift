// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SwiftOS",
    platforms: [.macOS(.v14)],
    products: [],
    targets: [
        .target(
            name: "Kernel",
            dependencies: ["CSupport", "Boot"],
            path: "Sources/Kernel",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .unsafeFlags([
                    "-wmo",
                    "-Xfrontend", "-disable-stack-protector",
                    "-Xfrontend", "-disable-stack-protector",
                    // TODO: add kasan
                    // "-sanitize=address",
                    // "-Xc", "-fno-sanitize-address-globals",
                ]),
            ]
        ),
        .target(
            name: "Boot",
            path: "Sources/Boot",
            exclude: ["linker.ld"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CSupport",
            path: "Sources/CSupport",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-ffreestanding"
                ])
            ]
        ),
        .target(
            name: "InitialProcess",
            path: "Sources/InitialProcess",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-ffreestanding"])
            ]
        ),
        .plugin(
            name: "BuildImagePlugin",
            capability: .command(
                intent: .custom(
                    verb: "build-image", description: "Build the kernel image and ramdisk"),
                permissions: [.writeToPackageDirectory(reason: "Generate final build artifacts")]
            ),
            path: "Plugins/BuildImagePlugin"
        ),
    ]
)
