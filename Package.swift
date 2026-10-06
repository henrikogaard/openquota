// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "openquota",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "openquota", targets: ["OpenQuota"]),
        .library(name: "OpenQuotaCore", targets: ["OpenQuotaCore"])
    ],
    targets: [
        // Pure-Foundation core: providers, models, engine. Compiles on Linux so CI
        // can type-check and test everything except the AppKit/SwiftUI shell.
        .target(
            name: "OpenQuotaCore",
            path: "Sources/OpenQuotaCore"
        ),
        // Menu-bar app shell. Every file is #if os(macOS) — builds to an empty
        // binary on Linux.
        .executableTarget(
            name: "OpenQuota",
            dependencies: ["OpenQuotaCore"],
            path: "Sources/OpenQuota"
        ),
        .testTarget(
            name: "OpenQuotaCoreTests",
            dependencies: ["OpenQuotaCore"],
            path: "Tests/OpenQuotaCoreTests"
        )
    ]
)
