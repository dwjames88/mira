// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiraCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MiraCore", targets: ["MiraCore"]),
        .executable(name: "mira-sheet", targets: ["MiraSheet"]),
    ],
    targets: [
        .target(
            name: "MiraCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MiraSheet",
            dependencies: ["MiraCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MiraCoreTests",
            dependencies: ["MiraCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
