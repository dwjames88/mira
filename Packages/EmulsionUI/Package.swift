// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EmulsionUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EmulsionUI", targets: ["EmulsionUI"])
    ],
    dependencies: [
        .package(path: "../EmulsionCore")
    ],
    targets: [
        .target(
            name: "EmulsionUI",
            dependencies: [.product(name: "EmulsionCore", package: "EmulsionCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
