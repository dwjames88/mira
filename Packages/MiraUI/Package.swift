// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiraUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MiraUI", targets: ["MiraUI"])
    ],
    dependencies: [
        .package(path: "../MiraCore")
    ],
    targets: [
        .target(
            name: "MiraUI",
            dependencies: [.product(name: "MiraCore", package: "MiraCore")],
            resources: [.copy("Resources/Fonts")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MiraUITests",
            dependencies: ["MiraUI", .product(name: "MiraCore", package: "MiraCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
