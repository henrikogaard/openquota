// swift-tools-version: 6.0
import PackageDescription

// zstd: Codex compresses older session logs to .jsonl.zst, and neither macOS
// nor Foundation can read that format.
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/facebook/zstd", from: "1.5.6")
]
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
        // System SQLite on Linux; macOS uses the SDK's SQLite3 module.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "OpenQuotaCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                .product(name: "libzstd", package: "zstd"),
            ],
            path: "Sources/OpenQuotaCore",
            resources: [.process("Resources")]
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
            // libzstd: tests compress their own fixtures.
            dependencies: ["OpenQuotaCore", .product(name: "libzstd", package: "zstd")],
            path: "Tests/OpenQuotaCoreTests"
        )
    ]
)
