// swift-tools-version: 6.0
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var openQuotaDependencies: [Target.Dependency] = ["OpenQuotaCore"]

// Sparkle is macOS-only; declare it only when the manifest evaluates on macOS
// so `swift build`/`swift test` stay clean on Linux CI.
#if os(macOS)
packageDependencies.append(
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
)
openQuotaDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
#endif

let package = Package(
    name: "openquota",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "openquota", targets: ["OpenQuota"]),
        .executable(name: "openquota-bridge", targets: ["OpenQuotaBridge"]),
        .library(name: "OpenQuotaCore", targets: ["OpenQuotaCore"])
    ],
    dependencies: packageDependencies,
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
            dependencies: openQuotaDependencies,
            path: "Sources/OpenQuota"
        ),
        .executableTarget(
            name: "OpenQuotaBridge",
            dependencies: ["OpenQuotaCore"],
            path: "Sources/OpenQuotaBridge"
        ),
        .testTarget(
            name: "OpenQuotaCoreTests",
            dependencies: ["OpenQuotaCore"],
            path: "Tests/OpenQuotaCoreTests"
        )
    ]
)
