// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiraCamera",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "MiraCameraKit", targets: ["MiraCameraKit"]),
        .library(name: "MiraCamera", targets: ["MiraCamera"]),
    ],
    dependencies: [
        .package(path: "../MiraCore"),
        .package(path: "../MiraUI"),
    ],
    targets: [
        // PURE layer: no AVFoundation, UIKit, Photos or SwiftUI. Builds and tests on the Mac.
        .target(
            name: "MiraCameraKit",
            dependencies: [.product(name: "MiraCore", package: "MiraCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // PLATFORM layer: every file is wrapped in `#if os(iOS)`, so it is empty on macOS.
        .target(
            name: "MiraCamera",
            dependencies: [
                "MiraCameraKit",
                .product(name: "MiraCore", package: "MiraCore"),
                .product(name: "MiraUI", package: "MiraUI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MiraCameraKitTests",
            dependencies: ["MiraCameraKit", .product(name: "MiraCore", package: "MiraCore")],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
