// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiraCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MiraCore", targets: ["MiraCore"]),
        .executable(name: "mira-sheet", targets: ["MiraSheet"]),
        // The in-app updater logic (GitHub releases, versions, verification, swap). Linked by the app only.
        .library(name: "MiraUpdates", targets: ["MiraUpdates"]),
    ],
    targets: [
        .target(
            name: "MiraCore",
            // Precompiled Core Image kernels (scripts/build-kernels.sh).
            resources: [.copy("Resources/Grade.ci.metallib")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MiraSheet",
            dependencies: ["MiraCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MiraUpdates",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MiraUpdatesTests",
            dependencies: ["MiraUpdates"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MiraCoreTests",
            dependencies: ["MiraCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
