// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-command-line-kit",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "CommandLineKitCore", targets: ["CommandLineKitCore"]),
        .library(name: "CommandLineKit", targets: ["CommandLineKit"]),
        .library(name: "CommandLineKitPipeline", targets: ["CommandLineKitPipeline"]),
        .library(name: "CommandLineKitInput", targets: ["CommandLineKitInput"]),
        .library(name: "CommandLineKitTesting", targets: ["CommandLineKitTesting"])
    ],
    targets: [
        .target(name: "CommandLineKitCore"),
        .target(name: "CommandLineKit", dependencies: ["CommandLineKitCore"]),
        .target(name: "CommandLineKitPipeline", dependencies: ["CommandLineKitCore"]),
        .target(name: "CommandLineKitInput", dependencies: ["CommandLineKitCore"]),
        .target(name: "CommandLineKitTesting", dependencies: ["CommandLineKitCore", "CommandLineKitInput"]),
        .testTarget(
            name: "CommandLineKitTests",
            dependencies: [
                "CommandLineKit",
                "CommandLineKitInput",
                "CommandLineKitPipeline",
                "CommandLineKitTesting"
            ]
        )
    ]
)
