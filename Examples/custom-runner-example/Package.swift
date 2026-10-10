// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// SwiftPM derives a path dependency's identity from its directory name, which differs
/// when the repo is mounted under another name (e.g. /w in docker).
let rootPackageIdentity = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent
    .lowercased()

/// Proof of the extension seam: this package depends on the Core contract and the Testing helpers only,
/// never on the default engine (`CommandLineKit`).
let package = Package(
    name: "custom-runner-example",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "CustomRunnerExample", targets: ["CustomRunnerExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "CustomRunnerExample",
            dependencies: [.product(name: "CommandLineKitCore", package: rootPackageIdentity)]
        ),
        .testTarget(
            name: "CustomRunnerExampleTests",
            dependencies: [
                "CustomRunnerExample",
                .product(name: "CommandLineKitTesting", package: rootPackageIdentity)
            ]
        )
    ]
)
