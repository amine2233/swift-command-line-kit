// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// SwiftPM derives a path dependency's identity from its directory name, which differs
/// when the repo is mounted under another name (e.g. /w in docker).
let rootPackageIdentity = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent
    .lowercased()

let package = Package(
    name: "sample-cli-app",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../../.."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "sample-cli-app",
            dependencies: [
                .product(name: "CommandLineKit", package: rootPackageIdentity),
                .product(name: "CommandLineKitInput", package: rootPackageIdentity),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
