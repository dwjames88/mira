// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EmulsionCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EmulsionCore", targets: ["EmulsionCore"])
    ],
    targets: [
        .target(
            name: "EmulsionCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EmulsionCoreTests",
            dependencies: ["EmulsionCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
