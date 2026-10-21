// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EmulsionCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EmulsionCore", targets: ["EmulsionCore"]),
        .executable(name: "emulsion-sheet", targets: ["EmulsionSheet"]),
    ],
    targets: [
        .target(
            name: "EmulsionCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "EmulsionSheet",
            dependencies: ["EmulsionCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EmulsionCoreTests",
            dependencies: ["EmulsionCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
